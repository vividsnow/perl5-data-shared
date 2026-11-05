use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();
use POSIX ();
use Cwd ();
use Data::Shared qw(shared_get shared_set shared_call shared_compile sharedc_call);

my $probe = Data::Shared->new(tempdir(CLEANUP => 1));
eval { $probe->mount('p', 'hashmap:ii', undef, 16); 1 }
    or plan skip_all => "hashmap backend unavailable: $@";

sub bytes_under {
    my ($dir) = @_;
    my $total = 0;
    my @queue = ($dir);
    while (my $d = shift @queue) {
        opendir my $h, $d or next;
        for my $e (readdir $h) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            -d $p ? push @queue, $p : ($total += -s $p || 0);
        }
    }
    return $total;
}

# unmount retains storage by design, but nothing removed it afterwards: a
# later mount of the same name adopted it, so a store the caller believed it
# had emptied served the old data, and a program that rotates mounts grew on
# disk without bound.
subtest 'unlink_all removes storage an unmount retained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        $root->mount('cache', 'hashmap:ii', undef, 100);
        $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
        shared_set($root, '/cache/1', 111);
        shared_set($root, '/users/alice/1', 222);
        $root->unmount($_) for $root->mounts;
        cmp_ok bytes_under($dir), '>', 0, 'the storage is still there after unmounting';
        $root->unlink_all;
        is bytes_under($dir), 0, 'and unlink_all removes it';
    }
    my $fresh = Data::Shared->new($dir);
    $fresh->mount('cache', 'hashmap:ii', undef, 100);
    $fresh->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    is shared_get($fresh, '/cache/1'), undef, 'a fresh store does not serve the old value';
    is_deeply [$fresh->children('/users')], [], 'nor the old children';
};

subtest 'unmount can remove the storage with it' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('cache', 'hashmap:ii', undef, 100);
    shared_set($root, '/cache/1', 7);
    ok -e "$dir/cache.shm", 'the backing file exists';
    is $root->unmount('cache', unlink => 1), 1, 'unmount with unlink reports success';
    ok !-e "$dir/cache.shm", 'and the storage is gone';
    ok !eval { $root->unmount('cache', bogus => 1); 1 }, 'an unknown option is refused';
    like $@, qr/unknown unmount option/, 'and named';
};

# The POD says a transient mount is not written to the manifest, but
# republishing it bumped the revision, so every sibling process was told its
# topology was stale -- which breaks forked workers each taking a scratch handle.
subtest 'a transient mount does not publish a revision' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('shared', 'hashmap:ii', undef, 100);
    my $revision = $root->{_revision};
    # Without this the assertions below compare undef with undef, which passes,
    # so the whole subtest would survive the counter being renamed away.
    ok defined $revision, 'the revision counter exists';
    my $before = do { open my $f, '<', "$dir/manifest.json" or die $!; local $/; <$f> };

    my $handle = Data::HashMap::Shared::II->new(undef, 16);
    $root->mount('scratch', $handle);
    is $root->{_revision}, $revision, 'the revision is unchanged';
    my $after = do { open my $f, '<', "$dir/manifest.json" or die $!; local $/; <$f> };
    is $after, $before, 'and the manifest is byte-identical';

    $root->unmount('scratch');
    is $root->{_revision}, $revision, 'unmounting it does not publish either';
    $root->mount('real', 'hashmap:ii', undef, 16);
    cmp_ok $root->{_revision}, '>', $revision, 'but a real mount still does';
};

# Only the manifest recorded a composite's child chain, and a remount rewrites
# it, so mounting over a retained directory with another child type was
# accepted and the children already there became unreadable.
subtest 'a composite remembers what its storage was created for' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    plan skip_all => 'bloomfilter backend unavailable'
        unless eval { $root->mount('users', ['hashmap:ss', 100, ['bloomfilter', 1000, 0.01]]); 1 };
    shared_set($root, '/users/alice/e1', 1);
    $root->unmount('users');
    ok !eval { $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]); 1 },
        'a different child type is refused';
    like $@, qr/storage was created for/, 'and says what it was created for';
    ok eval { $root->mount('users', ['hashmap:ss', 100, ['bloomfilter', 1000, 0.01]]); 1 },
        'the same chain still mounts' or diag $@;
    is shared_get($root, '/users/alice/e1'), 1, 'with its children intact';
};

# Removing a mount's storage through the native escape hatch left the manifest
# naming it, and then no process could open the store at all.
subtest 'a native unlink retires the mount with the storage' => sub {
    for my $tier (['string', sub { shared_call($_[0], '/cache', 'unlink') }],
                  ['compiled', sub { sharedc_call($_[0], shared_compile('/cache'), 'unlink') }]) {
        my ($label, $call) = @$tier;
        my $dir = tempdir(CLEANUP => 1);
        {
            my $root = Data::Shared->new($dir);
            $root->mount('cache', 'hashmap:ii', undef, 100);
            $root->mount('keep', 'hashmap:ii', undef, 16);
            shared_set($root, '/cache/1', 7);
            shared_set($root, '/keep/1', 9);
            $call->($root);
            ok !(grep { $_ eq 'cache' } $root->mounts), "$label: the mount is gone";
            ok((grep { $_ eq 'keep' } $root->mounts), "$label: the others stay");
        }
        my $reopened = eval { Data::Shared->open($dir) };
        ok $reopened, "$label: the store still opens" or diag $@;
        is eval { shared_get($reopened, '/keep/1') }, 9, "$label: and reads what is left"
            if $reopened;
    }
};

# Recorded in this root's memory only, the retained list died with the process
# that unmounted: the next one could not reclaim the storage with unlink_all,
# and a same-named remount served the old data back.
subtest 'another process reclaims what an unmount retained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    {
        my $a = Data::Shared->new($dir);
        $a->mount('keep', 'hashmap:ii', undef, 16);
        $a->mount('cache', 'hashmap:ii', undef, 100);
        $a->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
        shared_set($a, '/cache/1', 111);
        shared_set($a, '/users/alice/1', 222);
        $a->unmount($_) for qw(cache users);
    }
    my $b = Data::Shared->open($dir);
    is_deeply [$b->mounts], ['keep'], 'the survivor is the only mount';
    ok $b->unlink_all, 'unlink_all succeeds';
    is bytes_under($dir), 0, 'and reclaims the storage the other process retained';
    ok !-d "$dir/.children", 'including the composite child directory';

    my $c = Data::Shared->new($dir);
    $c->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    is shared_get($c, '/users/alice/1'), undef, 'a later mount does not resurrect it';
};

subtest 'unlink_all counts what it removed, not what was retained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    for my $i (1 .. 20) {
        $root->mount('s', 'hashmap:ii', undef, 16);
        shared_set($root, '/s/1', $i);
        $root->unmount('s');
    }
    is $root->unlink_all, 2, 'one backing file and the manifest';
    is bytes_under($dir), 0, 'and nothing is left on disk';
};

# One handle can be mounted twice on purpose, and the alias is transient, so
# retiring it published nothing while removing the file its persistent owner is
# recorded under: no process could open the store again.
subtest 'storage shared with another mount is not unlinked' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    my $handle = $root->mount('cache', 'hashmap:ss', undef, 100);
    shared_set($root, '/cache/k', 'v');
    $root->mount('alias', $handle);
    for my $how (['unmount', sub { $_[0]->unmount('alias', unlink => 1) }],
                 ['shared_call', sub { shared_call($_[0], '/alias', 'unlink') }]) {
        my ($label, $call) = @$how;
        ok !eval { $call->($root); 1 }, "$label: refused";
        like $@, qr/shares its storage with 'cache'/, "$label: and says with which mount";
    }
    ok -e "$dir/cache.shm", 'the owner still has its storage';
    ok $root->unmount('alias'), 'unmounting the alias without unlink is fine';
    undef $root; undef $handle;
    ok eval { Data::Shared->open($dir) }, 'and the store still opens' or diag $@;
};

# Removed after the lock was released, a sibling that had already read the new
# manifest could mount the same name onto the file that was about to go.
subtest 'storage is removed while the topology lock is held' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stamp = "$dir/removed-at";
    # A barrier, not a sleep: the child is released the moment the removal
    # BEGINS, which is the moment the lock is either held or already gone. A
    # sleep on either side proved nothing -- late scheduling made the ordering
    # come out right whether or not the lock was held.
    pipe my $entered_r, my $entered_w or die "pipe: $!";
    # PERL_UNICODE puts :utf8 on a new handle, and syswrite refuses one.
    binmode $_, ':raw' for $entered_r, $entered_w;
    my $root = Data::Shared->new($dir);
    $root->mount('keep', 'hashmap:ii', undef, 16);
    $root->mount('scratch', SlowUnlink->new($stamp, $entered_w));

    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        close $entered_w;
        my $go = <$entered_r>;                  # the removal has started
        POSIX::_exit(1) unless defined $go && $go =~ /removing/;
        # Stamped only after the topology change really happened, and the exit
        # status reports that rather than the signal: stamping unconditionally
        # meant the timing came out right even if this process never mounted
        # anything, so the test proved nothing about the lock.
        my $other = eval { Data::Shared->open($dir) } or POSIX::_exit(2);
        eval { $other->mount('sibling', 'hashmap:ii', undef, 16); 1 } or POSIX::_exit(3);
        CORE::open(my $fh, '>', "$dir/locked-at") or POSIX::_exit(4);
        print $fh Time::HiRes::time();
        close $fh or POSIX::_exit(5);
        POSIX::_exit(0);
    }
    close $entered_r;
    $root->unmount('scratch', unlink => 1);
    waitpid $pid, 0;
    is $?, 0, 'the sibling opened the store and mounted, released by the removal';

    my $removed = -e $stamp ? do { open my $f, '<', $stamp; local $/; <$f> } : '';
    my $locked = -e "$dir/locked-at" ? do { open my $f, '<', "$dir/locked-at"; local $/; <$f> } : '';
    ok length $removed, 'the removal ran';
    ok length $locked, 'the sibling changed topology';
    cmp_ok $locked, '>', $removed, 'only after the storage was gone';
    my $after = Data::Shared->open($dir);
    ok((grep { $_ eq 'sibling' } $after->mounts), 'and its mount is in the published manifest');
};

# The ledger is published and read by another process, so a root opened as a
# relative path recorded a relative one, which the next process resolved
# against its own working directory and removed whatever sat there.
subtest 'retained paths are recorded against the root, not the caller' => sub {
    my $base = tempdir(CLEANUP => 1);
    my $elsewhere = tempdir(CLEANUP => 1);
    my $start = Cwd::getcwd();
    chdir $base or die $!;
    {
        my $r = Data::Shared->new('state');       # a relative root, as a daemon may use
        $r->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
        shared_set($r, '/users/alice/1', 42);
        $r->unmount('users');
    }
    my $manifest = do { open my $fh, '<', "$base/state/manifest.json" or die $!; local $/; <$fh> };
    chdir $elsewhere or die $!;
    # The requirement is that an entry does not depend on the working
    # directory of whoever reads it, which an entry relative to the root
    # satisfies and one relative to the caller does not.
    my ($entry) = $manifest =~ /"retained"\s*:\s*\[\s*"([^"]+)"/;
    ok defined $entry, 'the ledger records the retained storage';
    # The root was created as 'state' from $base, so the two spellings differ:
    # relative to the root is '.children/users' and relative to the caller
    # would be 'state/.children/users'. Accepting either told them apart from
    # nothing, and the entry is not absolute at all.
    is $entry, '.children/users', 'the entry is relative to the root';
    ok -e "$base/state/$entry", 'and resolves there';
    # The next process opens it by absolute path from a different directory: a
    # relative entry resolved against this cwd instead, removing whatever sat
    # there and leaving the store's own storage behind.
    my $n = eval { Data::Shared->open("$base/state")->unlink_all };
    my $err = $@;
    chdir $start or die $!;
    is $n, 2, 'unlink_all reclaims it from another directory' or diag $err;
    ok !-d "$base/state/.children/users", 'the composite directory is gone';
};

# Ownership is a property of the storage, not the object: an alias kept across
# a remount points at a new handle object on the same file.
subtest 'a handle reopened onto the same storage is still shared' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    my $handle = $root->mount('cache', 'hashmap:ss', undef, 100);
    shared_set($root, '/cache/k', 'v');
    $root->mount('alias', $handle);
    $root->unmount('cache');
    $root->mount('cache', 'hashmap:ss', undef, 100);   # adopts, new handle object
    ok !eval { $root->unmount('alias', unlink => 1); 1 }, 'the stale alias cannot unlink it';
    like $@, qr/shares its storage with 'cache'/, 'and names the owner';
    ok -e "$dir/cache.shm", 'the owner keeps its storage';

    my $solo = Data::Shared->new(tempdir(CLEANUP => 1));
    $solo->mount('only', 'hashmap:ss', undef, 100);
    is $solo->unmount('only', unlink => 1), 1, 'a mount sharing nothing still unlinks';
};

# The manifest is removed first, so without counting the ledger the retry a
# caller makes after fixing what blocked the cleanup returned 0 and looked
# like success.
subtest 'a failed retained cleanup can be retried' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $hold = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('ext', 'hashmap:ii', "$hold/ext.shm", 16);
    shared_set($root, '/ext/1', 5);
    $root->unmount('ext');
    chmod 0500, $hold or die $!;
    plan skip_all => 'running as a user that ignores directory permissions'
        if unlink "$hold/ext.shm";
    ok !eval { $root->unlink_all; 1 }, 'the blocked cleanup reports failure';
    like $@, qr/cannot clean|Permission denied/, 'naming what it could not remove';
    ok -e "$hold/ext.shm", 'and the storage survives';
    chmod 0700, $hold or die $!;
    is $root->unlink_all, 1, 'the retry removes it';
    ok !-e "$hold/ext.shm", 'and the storage is gone';
};

# Recorded absolute, tearing down an archived copy of a store removed whatever
# now sat at the path it had been created under -- a live root's storage -- and
# left its own behind.
subtest 'an archived root reclaims its own storage, not its successor' => sub {
    my $base = tempdir(CLEANUP => 1);
    my $live = "$base/state";
    {
        my $old = Data::Shared->new($live);
        $old->mount('cache', 'hashmap:ii', undef, 64);
        shared_set($old, '/cache/1', 1);
        $old->unmount('cache');
    }
    rename $live, "$base/state.old" or die "rename: $!";
    my $new = Data::Shared->new($live);
    $new->mount('cache', 'hashmap:ii', undef, 64);
    shared_set($new, '/cache/1', 42);

    Data::Shared->open("$base/state.old")->unlink_all;
    ok -e "$live/cache.shm", "the live root's storage is untouched";
    ok !-e "$base/state.old/cache.shm", "the archived root's own storage is gone";
    is shared_get($new, '/cache/1'), 42, 'the live root still reads';
    undef $new;
    ok eval { Data::Shared->open($live) }, 'and still opens' or diag $@;
};

# A composite records its whole directory and its children's files live below
# it, so an equality test on storage paths let a mounted child handle unlink a
# file the parent index still named.
subtest 'a mounted composite child handle cannot unlink its storage' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    shared_set($root, '/users/alice/1', 42);
    my $child = $root->handle('/users/alice');
    ok $child, 'the documented child handle';
    $root->mount('alias', $child);
    ok !eval { $root->unmount('alias', unlink => 1); 1 }, 'retiring it with unlink is refused';
    like $@, qr/shares its storage with 'users'/, 'naming the composite that owns it';
    ok $root->exists('/users/alice'), 'the child is still registered';
    undef $root; undef $child;
    my $re = Data::Shared->open($dir);
    is $re->get('/users/alice/1'), 42, 'and another process can still read it';
};

# Cwd returns bytes, so an entry recorded from a root whose directory the
# caller held as characters was resolved against a character string: the name
# that came out did not exist, unlink_all skipped the storage and then dropped
# its own record of it, leaving the file unreclaimable.
subtest 'a retained entry resolves against a wide-character root' => sub {
    my $base = tempdir(CLEANUP => 1);
    my $dir = "$base/\x{3b1}root";
    my $root = Data::Shared->new($dir);
    eval { $root->mount('m', 'hashmap:ii', "$dir/\x{3b2}store.shm", 64); 1 }
        or plan skip_all => "wide-character paths unavailable: $@";
    shared_set($root, '/m/1', 7);
    $root->unmount('m');
    is scalar(() = glob "$dir/*.shm"), 1, 'the retained file is on disk';
    # A stray the ledger never named, which only the directory sweep can
    # reach: readdir answers in bytes, and joining them to this character
    # string tested a path that does not exist, so the sweep walked past it.
    my $stray = "$dir/\x{3b3}stray.shm";
    { my $h = Data::HashMap::Shared::II->new($stray, 16) }
    ok -f $stray, 'and an unpublished stray beside it';
    ok $root->unlink_all, 'unlink_all succeeds';
    is scalar(() = glob "$dir/*.shm"), 0, 'and the retained file is really gone';
    ok !-f $stray, 'and so is the stray';
    opendir my $dh, $dir or die $!;
    my @left = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    is_deeply \@left, ['.manifest.lock'], 'leaving only the lock, as under an ASCII root';
};

# The ownership check runs before _mutate scopes the path cache, so a rotation
# left one memo per retired path in the root for its whole lifetime.
subtest 'rotating mounts does not grow the root' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    for my $i (1 .. 50) {
        $root->mount("rot$i", 'hashmap:ii', undef, 16);
        $root->unmount("rot$i", unlink => 1);
    }
    is_deeply [$root->mounts], [], 'every rotation was retired';
    # Absent, not merely empty: the cache is localized per operation, so
    # between them the key is gone entirely. That is the strongest form of
    # "nothing was retained", and asserting that it exists would be wrong.
    ok !exists $root->{_abs_cache} || !keys %{ $root->{_abs_cache} },
        'no resolved path is held after the operation that resolved it';
    # Likewise: without this the comparison below is 0 == 0 on a store whose
    # manifest has gone.
    ok -e "$dir/manifest.json", 'the manifest is still there';
    is bytes_under($dir), -s "$dir/manifest.json", 'only the manifest is left on disk';
};

# A teardown is the one operation allowed to run against a dead instance: it
# is what makes it dead. Treating an absent index as retired meant a destroy
# that removed the index and then failed to remove the directory could never be
# retried, and the store could not be opened either.
subtest 'a teardown blocked part-way can be retried' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    eval { $root->mount('users', ['hashmap:ss', 100, ['hashmap:ss', 100]]); 1 }
        or plan skip_all => "composite unavailable: $@";
    shared_set($root, '/users/alice/k', 'v');
    $root->freeze_all;
    chmod 0500, "$dir/.children" or die $!;
    plan skip_all => 'running as a user that ignores directory permissions'
        if rmdir "$dir/.children/users";
    ok !eval { $root->unlink_all; 1 }, 'the blocked teardown reports failure';
    ok -d "$dir/.children/users", 'and leaves the directory it could not remove';
    chmod 0700, "$dir/.children" or die $!;
    ok $root->unlink_all, 'the retry completes';
    ok !-d "$dir/.children/users", 'the directory is gone';
    ok !-e "$dir/manifest.json", 'and so is the manifest';
};

# The retry above keeps the same root object. A process killed part-way
# through a teardown does not, and the manifest it leaves behind has to be
# replayable by somebody else: it used to name storage that was already
# gone, which open, new and open_sealed all refuse, so the remains could
# only be removed by hand.
# destroy marks the index 'x:' before it removes anything, so a composite
# can be met already tombstoned. Cleanup is exempt from the 'instance was
# deleted' refusal for exactly that reason -- an exemption mutation cannot
# reach, because the croak it prevents is caught upstream: with it removed
# the teardown still completes, so only the outcome can be asserted. The
# counter probe in tmp/r35/cleanup-count.pl shows the exemption taken twice
# in this very scenario.
subtest 'teardown completes over an already tombstoned composite' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    eval { $root->mount('u', ['hashmap:ss', 64, ['hashmap:ii', 16]]); 1 }
        or plan skip_all => "composite unavailable: $@";
    shared_set($root, '/u/alice/1', 1);
    $root->{mounts}{u}{composite}{index}->put('x:', 1);
    ok $root->unlink_all, 'the teardown reports work done';
    ok !-d "$dir/.children/u", 'the composite directory is gone';
    ok !-e "$dir/manifest.json", 'and so is the manifest';
};

subtest 'a teardown killed part-way is finished by another process' => sub {
    my $dir = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        eval { $root->mount('a', 'hashmap:ii', undef, 64); 1 }
            or plan skip_all => "hashmap unavailable: $@";
        $root->mount('b', 'hashmap:ii', undef, 64);
        shared_set($root, '/a/1', 1);
        shared_set($root, '/b/1', 1);
    }
    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        my $root = Data::Shared->open($dir);
        my $seen = 0;
        no warnings 'redefine';
        my $orig = \&Data::HashMap::Shared::II::unlink;
        # The first mount's storage goes; the process dies before the second.
        local *Data::HashMap::Shared::II::unlink = sub {
            kill 9, $$ if $seen++;
            return $orig->(@_);
        };
        eval { $root->unlink_all };
        POSIX::_exit(0);
    }
    waitpid $pid, 0;
    is $? & 127, 9, 'the worker died mid-teardown';
    ok !-e "$dir/a.shm", 'the first storage is gone';
    ok -e "$dir/b.shm", 'the second is still there';
    my $next = eval { Data::Shared->open($dir) };
    ok $next, 'and another process can still open the store' or diag $@;
    is_deeply [$next ? $next->mounts : ('did not open')], [],
        'which replays an empty topology';
    ok $next && $next->unlink_all, 'whose own teardown finishes the job';
    ok !-e "$dir/b.shm", 'the stranded storage is reclaimed';
    ok !-e "$dir/manifest.json", 'and the manifest is gone';
};

# Between publishing a manifest without the mount and removing its storage,
# the file was named by nothing: not the manifest, not the ledger. A process
# killed there left a file a later same-named mount adopted -- serving old data
# -- that no call could reclaim. The ledger now covers that window.
subtest 'a kill between the publish and the removal leaves the file reclaimable' => sub {
    my $dir = tempdir(CLEANUP => 1);
    # Held outside the root: unlink_all also sweeps stray .shm files in the
    # root directory, so a backing file inside it would be reclaimed whether
    # or not the ledger named it, and the assertion below would pass with the
    # ledger ignored entirely.
    my $hold = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        $root->mount('m1', 'hashmap:ss', "$hold/m1.shm", 128);
        shared_set($root, '/m1/secret', 'olddata');
    }
    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        my $root = Data::Shared->open($dir);
        no warnings 'redefine';
        # The only way into that window: die where the removal would have run.
        local *Data::Shared::_retire_storage = sub { kill 9, $$ };
        $root->unmount('m1', unlink => 1);
        POSIX::_exit(0);
    }
    waitpid $pid, 0;
    is $? & 127, 9, 'the worker died in the window';
    ok -e "$hold/m1.shm", 'its storage is still on disk';
    my $manifest = do { open my $fh, '<', "$dir/manifest.json" or die $!; local $/; <$fh> };
    unlike $manifest, qr/"m1"/, 'the manifest no longer names the mount';
    like $manifest, qr/"retained"\s*:\s*\[[^\]]*m1/, 'but the ledger names the storage';
    my $next = Data::Shared->open($dir);
    ok $next->unlink_all, 'so another process can reclaim it';
    ok !-e "$hold/m1.shm", 'and the storage is gone';
    # What the window costs if it is not reclaimed: a later mount of the same
    # name adopts the file and serves what the dead process had written.
    my $again = Data::Shared->new($dir);       # unlink_all took the manifest too
    $again->mount('m1', 'hashmap:ss', "$hold/m1.shm", 128);
    is shared_get($again, '/m1/secret'), undef, 'and a remount starts empty';
};

# The complement of the kill window above: once the removal succeeds the entry
# must leave the PUBLISHED ledger as well. Left on it, a path this store no
# longer owns stayed listed for good, and the next process's unlink_all removed
# whatever had since been created there.
subtest 'a completed removal leaves the published ledger' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $hold = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('ext', 'hashmap:ii', "$hold/ext.shm", 16);
    shared_set($root, '/ext/1', 5);
    $root->unmount('ext', unlink => 1);
    ok !-e "$hold/ext.shm", 'the storage is gone';
    my $manifest = do { open my $fh, '<', "$dir/manifest.json" or die $!; local $/; <$fh> };
    unlike $manifest, qr/ext\.shm/, 'and the ledger no longer names the path';

    # Storage outside the root is recorded absolute, so a stale entry names a
    # path another program may now be using.
    open my $fh, '>', "$hold/ext.shm" or die $!;
    print $fh 'someone else' or die $!;
    close $fh or die $!;
    Data::Shared->open($dir)->unlink_all;
    ok -e "$hold/ext.shm", 'and another process leaves a foreign file there alone';
};

# The POD promises teardown leaves nothing but the lock, and the composite
# equivalent of this is already swept, but a backing file created by a
# coordinator that died before publishing the manifest is named by nothing --
# so it survived unlink_all and no API could even report it.
subtest 'teardown reclaims a backing file no manifest ever named' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('cache', 'hashmap:ii', undef, 64);
    shared_set($root, '/cache/7', 42);

    my $orphan = "$dir/scratch.shm";
    { my $h = Data::HashMap::Shared::II->new($orphan, 16) }
    ok -f $orphan, 'an unpublished backing file is on disk';
    is $root->mount_info('scratch'), undef, 'and no mount record names it';

    # What a publication killed between its temporary file and the rename
    # leaves behind. The manifest itself is intact, so nothing names it.
    my $temp = "$dir/.manifest-Aa0Bb1Cc";
    { open my $fh, '>', $temp or die $!; print $fh "{}\n" }
    ok -f $temp, 'and an abandoned publication temp is on disk';

    my $n = $root->unlink_all;
    ok !-f $orphan, 'teardown removes it too';
    ok !-f $temp, 'and the abandoned temp with it';
    cmp_ok $n, '>=', 3, 'and counts it among what it removed';
    opendir my $dh, $dir or die $!;
    my @left = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    is_deeply \@left, ['.manifest.lock'], 'leaving only the lock, as documented';
};

done_testing;

package SlowUnlink;
sub new {
    my ($class, $stamp, $signal) = @_;
    return bless { stamp => $stamp, signal => $signal }, $class;
}
sub unlink {
    my ($self) = @_;
    syswrite $self->{signal}, "removing\n";     # releases the sibling
    select undef, undef, undef, 0.6;            # a window, not a synchroniser
    open my $fh, '>', $self->{stamp} or die $!;
    print $fh Time::HiRes::time();
    close $fh or die $!;
    return 1;
}
