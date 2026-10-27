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
    my $root = Data::Shared->new($dir);
    $root->mount('keep', 'hashmap:ii', undef, 16);
    $root->mount('scratch', SlowUnlink->new($stamp));

    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        select undef, undef, undef, 0.2;        # land inside the removal
        my $other = eval { Data::Shared->open($dir) };
        $other->mount('sibling', 'hashmap:ii', undef, 16) if $other;
        if (open my $fh, '>', "$dir/locked-at") {
            print $fh Time::HiRes::time();
            close $fh;
        }
        POSIX::_exit(0);
    }
    $root->unmount('scratch', unlink => 1);
    waitpid $pid, 0;

    my $removed = -e $stamp ? do { open my $f, '<', $stamp; local $/; <$f> } : undef;
    my $locked = -e "$dir/locked-at" ? do { open my $f, '<', "$dir/locked-at"; local $/; <$f> } : undef;
    ok defined $removed && length $removed, 'the removal ran';
    ok defined $locked && length $locked, 'the sibling changed topology';
    cmp_ok $locked, '>', $removed, 'only after the storage was gone'
        if defined $removed && defined $locked && length $removed && length $locked;
};

# The ledger is published and read by another process, so a root opened as a
# relative path recorded a relative one, which the next process resolved
# against its own working directory and removed whatever sat there.
subtest 'retained paths are recorded absolute' => sub {
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
    like $manifest, qr{"retained"\s*:\s*\[\s*"/}, 'the ledger holds an absolute path';
    # The next process opens it by absolute path from a different directory: a
    # relative entry resolved against this cwd instead, removing whatever sat
    # there and leaving the store's own storage behind.
    my $next = Data::Shared->open("$base/state");
    is $next->unlink_all, 2, 'unlink_all reclaims it from another directory';
    chdir $start or die $!;
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
    ok -e "$hold/ext.shm", 'and the storage survives';
    chmod 0700, $hold or die $!;
    is $root->unlink_all, 1, 'the retry removes it';
    ok !-e "$hold/ext.shm", 'and the storage is gone';
};

done_testing;

package SlowUnlink;
sub new { my ($class, $stamp) = @_; return bless { stamp => $stamp }, $class }
sub unlink {
    my ($self) = @_;
    select undef, undef, undef, 0.6;
    open my $fh, '>', $self->{stamp} or die $!;
    print $fh Time::HiRes::time();
    close $fh or die $!;
    return 1;
}
