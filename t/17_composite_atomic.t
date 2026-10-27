use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Fcntl ();
use Time::HiRes ();
use Data::Shared qw(shared_compile sharedc_get);

eval { require Data::HashMap::Shared::SS; require Data::Sync::Shared::RWLock; 1 }
    or plan skip_all => "composite backends unavailable: $@";

sub maps {
    my ($root, %opt) = @_;
    $root->mount('users', { spec => 'hashmap:ss', args => [128],
        child => { spec => 'hashmap:ss', args => [128] }, max_children => 16,
        cache_size => 2, %opt });
}

subtest 'constructor failure releases the child budget and partial files' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, max_children => 1);
    my $construct = \&Data::Shared::_construct;
    {
        no warnings 'redefine';
        local *Data::Shared::_construct = sub {
            my ($context, $resolved, $name, @args) = @_;
            my @result = $construct->(@_);
            die "injected child failure\n" if $name eq 'child';
            return @result;
        };
        ok !eval { $root->set('/users/broken/key', 'bad'); 1 }, 'construction failed';
        like $@, qr/injected child failure/, 'original exception';
    }
    is_deeply [$root->children('/users')], [], 'no phantom registration';
    is $root->call('/users', 'child_count'), 0, 'budget released';
    is_deeply [glob($root->dir . '/.children/users/child-*')], [], 'partial child directory removed';
    $root->set('/users/good/key', 'ok');
    is $root->get('/users/good/key'), 'ok', 'next child can use the budget';
    ok -d $root->dir . '/.children/users/child-1', 'failed child ID was not reused';
};

subtest 'failed readiness publication is rolled back' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, max_children => 1);
    my $put = Data::HashMap::Shared::SS->can('put');
    {
        no warnings qw(redefine once);
        local *Data::HashMap::Shared::SS::put = sub {
            return 0 if $_[1] eq 'c:broken';
            return $put->(@_);
        };
        ok !eval { $root->set('/users/broken/key', 'bad'); 1 }, 'metadata failure propagated';
    }
    is_deeply [$root->children('/users')], [], 'address not published';
    is $root->call('/users', 'child_count'), 0, 'count restored';
    $root->set('/users/good/key', 'ok');
    is $root->get('/users/good/key'), 'ok', 'retry on another address works';
};

subtest 'score-only registration survives failed lazy construction' => sub {
    eval { require Data::SortedSet::Shared::Strings; 1 }
        or plan skip_all => "string sorted set unavailable: $@";
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('users', { spec => 'sortedset:strings', args => [{ max => 32 }],
        child => { spec => 'hashmap:ss', args => [16] }, max_children => 1 });
    $root->set('/users/alice', 100);
    my $construct = \&Data::Shared::_construct;
    {
        no warnings 'redefine';
        local *Data::Shared::_construct = sub {
            die "injected leaf failure\n" if $_[2] eq 'child';
            return $construct->(@_);
        };
        ok !eval { $root->set('/users/alice/name', 'x'); 1 }, 'leaf constructor failed';
    }
    is $root->get('/users/alice'), 100, 'score preserved';
    is_deeply [$root->children('/users')], ['alice'], 'registered address preserved';
    is $root->call('/users', 'child_count'), 1, 'existing reservation count preserved';
    $root->set('/users/alice/name', 'ok');
    is $root->get('/users/alice/name'), 'ok', 'reserved child can be retried';
};

subtest 'child count does not enumerate all addresses during writes' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, max_children => 64);
    {
        no warnings 'redefine';
        local *Data::Shared::Composite::_count_addresses = sub { die "unexpected registry scan\n" };
        $root->set("/users/$_/name", $_) for 1 .. 20;
        is $root->call('/users', 'child_count'), 20, 'counter tracks creation';
        $root->delete('/users/10');
        is $root->call('/users', 'child_count'), 19, 'counter tracks deletion';
    }
};

subtest 'file cache evicts the least recently used child' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, cache_size => 2);
    $root->set("/users/$_/name", $_) for qw(a b);
    $root->get('/users/a/name');
    $root->set('/users/c/name', 'c');
    is_deeply [sort keys %{ $root->stats->{users}{child_stats} }], [qw(a c)], 'recently touched child retained';
    is $root->get('/users/b/name'), 'b', 'evicted child reopens';
    is_deeply [sort keys %{ $root->stats->{users}{child_stats} }], [qw(b c)], 'oldest child evicted on reopen';
};

subtest 'missing child storage is not regenerated on a cache miss' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, cache_size => 1);
    $root->set('/users/a/key', 'a');
    $root->set('/users/b/key', 'b');
    my $path = $root->dir . '/.children/users/child-0/child.shm';
    unlink $path or die $!;
    ok !eval { $root->get('/users/a/key'); 1 }, 'missing child fails';
    like $@, qr/missing backing file/, 'missing file error';
    ok !-e $path, 'child file not recreated';
};

subtest 'concurrent first writers publish one shared child' => sub {
    local $SIG{ALRM} = sub { die "concurrent writers timed out\n" };
    alarm 20;
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    pipe my $ready_r, my $ready_w or die $!;
    pipe my $go_r, my $go_w or die $!;
    # PERL_UNICODE puts a :utf8 layer on every new handle, and sysread and
    # syswrite refuse one, so these barriers died under a smoker that sets it.
    binmode $_, ':raw' for $ready_r, $ready_w, $go_r, $go_w;
    my @pids;
    for my $i (1 .. 6) {
        my $pid = fork(); die $! unless defined $pid;
        if (!$pid) {
            $SIG{ALRM} = sub { _exit(124) }; alarm 15;
            close $ready_r; close $go_w;
            my $ok = eval {
                my $child = Data::Shared->open($root->dir);
                syswrite($ready_w, 'r') == 1 or die $!;
                sysread($go_r, my $go, 1) == 1 or die 'missing start signal';
                $child->set("/users/shared/key$i", "value$i");
                1;
            };
            warn $@ unless $ok;
            _exit($ok ? 0 : 1);
        }
        push @pids, $pid;
    }
    close $ready_w; close $go_r;
    my $ready = '';
    while (length $ready < 6) {
        sysread($ready_r, my $next, 6 - length $ready) > 0 or die 'worker exited before barrier';
        $ready .= $next;
    }
    syswrite($go_w, 'g' x 6) == 6 or die $!;
    close $go_w;
    for my $pid (@pids) { waitpid $pid, 0; is $?, 0, 'writer exited successfully' }
    is_deeply [$root->children('/users')], ['shared'], 'one address';
    is $root->call('/users', 'child_count'), 1, 'one budget slot';
    is_deeply [map { $root->get("/users/shared/key$_") } 1 .. 6],
        [map { "value$_" } 1 .. 6], 'every process wrote the same child instance';
    is_deeply [glob($root->dir . '/.children/users/child-*')], [$root->dir . '/.children/users/child-0'], 'one backing instance';
    alarm 0;
};

subtest 'another process deletes and recreates a compiled target' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    $root->set('/users/a/key', 'old');
    my $path = shared_compile('/users/a/key');
    is sharedc_get($root, $path), 'old', 'old target cached';
    my $old = $root->handle('/users/a');
    my $pid = fork(); die $! unless defined $pid;
    if (!$pid) {
        $SIG{ALRM} = sub { _exit(124) }; alarm 15;
        my $ok = eval {
            my $child = Data::Shared->open($root->dir);
            $child->delete('/users/a');
            $child->set('/users/a/key', 'new');
            1;
        };
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    waitpid $pid, 0;
    is $?, 0, 'delete/recreate succeeded';
    is sharedc_get($root, $path), 'new', 'compiled path resolves new generation';
    is $old->get('key'), 'old', 'explicit native handle retains old instance';
};

subtest 'deletion waits for in-progress construction' => sub {
    local $SIG{ALRM} = sub { die "construction/delete coordination timed out\n" };
    alarm 20;
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    pipe my $ready_r, my $ready_w or die $!;
    pipe my $release_r, my $release_w or die $!;
    pipe my $deleted_r, my $deleted_w or die $!;
    binmode $_, ':raw' for $ready_r, $ready_w, $release_r, $release_w, $deleted_r, $deleted_w;
    my $construct = \&Data::Shared::_construct;
    my $creator = fork(); die $! unless defined $creator;
    if (!$creator) {
        $SIG{ALRM} = sub { _exit(124) }; alarm 15;
        close $ready_r; close $release_w; close $deleted_r; close $deleted_w;
        my $ok = eval {
            my $child = Data::Shared->open($root->dir);
            no warnings 'redefine';
            local *Data::Shared::_construct = sub {
                if ($_[2] eq 'child') {
                    syswrite($ready_w, 'r') == 1 or die $!;
                    sysread($release_r, my $signal, 1) == 1 or die 'missing release';
                }
                return $construct->(@_);
            };
            $child->set('/users/a/key', 'value');
            1;
        };
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    close $ready_w; close $release_r;
    sysread($ready_r, my $ready, 1) == 1 or die 'creator did not reach constructor';
    my $deleter = fork(); die $! unless defined $deleter;
    if (!$deleter) {
        $SIG{ALRM} = sub { _exit(124) }; alarm 15;
        close $ready_r; close $release_w; close $deleted_r;
        my $ok = eval {
            $root->delete('/users/a');
            syswrite($deleted_w, 'd') == 1 or die $!;
            1;
        };
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    close $deleted_w;
    my $readable = '';
    vec($readable, fileno($deleted_r), 1) = 1;
    # Generous on purpose: this asserts the ABSENCE of a completion, so the
    # window has to be long enough that a deleter which ignored the lock would
    # certainly have finished within it. At 0.1s a loaded box gave the same
    # answer whether or not the lock was taken.
    is select($readable, undef, undef, 2), 0,
        'deletion has not completed while constructor holds the lock';
    syswrite($release_w, 'g') == 1 or die $!;
    close $release_w;
    for my $pid ($creator, $deleter) { waitpid $pid, 0; is $?, 0, 'coordinated process succeeded' }
    is_deeply [$root->children('/users')], [], 'completed child was detached';
    is $root->call('/users', 'child_count'), 0, 'budget returned';
    alarm 0;
};

subtest 'interrupted creation releases the lock and repairs the live counter' => sub {
    local $SIG{ALRM} = sub { die "interrupted creator timed out\n" };
    alarm 20;
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root, max_children => 1);
    pipe my $ready_r, my $ready_w or die $!;
    pipe my $wait_r, my $wait_w or die $!;
    binmode $_, ':raw' for $ready_r, $ready_w, $wait_r, $wait_w;
    my $construct = \&Data::Shared::_construct;
    my $pid = fork(); die $! unless defined $pid;
    if (!$pid) {
        $SIG{ALRM} = sub { _exit(124) }; alarm 15;
        close $ready_r; close $wait_w;
        my $ok = eval {
            my $child = Data::Shared->open($root->dir);
            no warnings 'redefine';
            local *Data::Shared::_construct = sub {
                my @result = $construct->(@_);
                if ($_[2] eq 'child') {
                    syswrite($ready_w, 'r') == 1 or die $!;
                    sysread($wait_r, my $unused, 1);
                    die 'unexpected release';
                }
                return @result;
            };
            $child->set('/users/interrupted/key', 'never published');
            1;
        };
        _exit($ok ? 0 : 1);
    }
    close $ready_w; close $wait_r;
    sysread($ready_r, my $ready, 1) == 1 or die 'constructor not reached';
    kill 9, $pid or die $!;
    waitpid $pid, 0;
    is $? & 127, 9, 'creator terminated before publication';
    is $root->call('/users', 'child_count'), 0, 'pending counter repaired under the released lock';
    is_deeply [$root->children('/users')], [], 'unfinished child was not published';
    $root->set('/users/good/key', 'value');
    is $root->get('/users/good/key'), 'value', 'budget usable by another writer';
    ok -d $root->dir . '/.children/users/child-1', 'interrupted ID not reused';
    ok -d $root->dir . '/.children/users/child-0', 'unpublished directory retained for explicit recovery';
    alarm 0;
};

subtest 'missing composite index cannot silently discard the hierarchy' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    $root->set('/users/a/key', 'saved');
    my $index = $root->dir . '/.children/users/index.shm';
    unlink $index or die $!;
    ok !eval { Data::Shared->open($root->dir); 1 }, 'missing index refused';
    like $@, qr/missing backing file.*index\.shm/, 'index path explained';
    ok !-e $index, 'index not rebuilt empty';
};

subtest 'legacy readiness markers and counters remain readable' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    $root->set('/users/a/key', 'saved');
    my $index = $root->{mounts}{users}{composite}{index};
    $index->put('c:a', 1);
    $index->remove('s:');
    my $again = Data::Shared->open($root->dir);
    is $again->get('/users/a/key'), 'saved', 'legacy child marker accepted';
    is $again->call('/users', 'child_count'), 1, 'counter initialized from legacy records';
};

subtest 'nested deletion retires the shared instance before cleanup' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('users', { spec => 'hashmap:ss', args => [32], cache_size => 1,
        child => { spec => 'hashmap:ss', args => [32], child => ['hashmap:ss', 16] } });
    $root->set('/users/a/b/key', 'saved');
    my $old = $root->{mounts}{users}{composite}{cache}{0}{comp};
    my $old_index = $old->{index};
    $root->set('/users/c/d/key', 'other');
    $root->delete('/users/a');
    is $old_index->get('x:'), 1, 'old mappings see retirement after cache eviction';
    ok !-d $root->dir . '/.children/users/child-0', 'old directory removed';
    $root->set('/users/a/b/key', 'new');
    is $root->get('/users/a/b/key'), 'new', 'fresh nested instance remains usable';
};

subtest 'freeze through call at a composite is refused, not half-applied' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    $root->set('/users/a/key', 'saved');
    ok !eval { $root->node('/users')->call('freeze'); 1 }, 'call(freeze) at a composite croaks';
    like $@, qr/cannot freeze composite mount 'users' through call\(\)/, 'and says why';
    like $@, qr/freeze_all/, 'and points at the tool that does it';
    # The point of refusing: the subtree must not be left half-sealed.
    ok eval { $root->set('/users/b/key', 'new'); 1 }, 'a new child still works';
    ok eval { $root->delete('/users/a'); 1 }, 'and delete still works';
    is $root->freeze_all >= 1, 1, 'freeze_all is the way to seal it';
};

subtest 'frozen composite storage can be unlinked by its producer' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    maps($root);
    $root->set('/users/a/key', 'saved');
    $root->freeze_all;
    ok $root->unlink_all >= 1, 'producer unlinked frozen root';
    ok !-e $root->dir . '/manifest.json', 'manifest removed';
    ok !-d $root->dir . '/.children/users', 'frozen composite directory removed';
};

# A store recreated at the same directory allocates child ids from zero again,
# so the old incarnation's child-0 path belongs to the new one. The deletion
# marker cannot catch a process that still holds the old index -- it reads its
# own copy -- and a destroy on a frozen index never writes one at all. Without
# the identity check this stale read returned the NEW store's data and the
# write landed in it.
subtest 'a stale composite cannot attach to a recreated store' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $spec = { spec => 'hashmap:ss', args => [100],
                 child => { spec => 'hashmap:ss', args => [100] }, cache_size => 1 };
    {
        my $maker = Data::Shared->new($dir);
        eval { $maker->mount('users', $spec); 1 } or plan skip_all => "composite unavailable: $@";
        $maker->set('/users/alice/k', 'alice-original');
        $maker->set('/users/carol/k', 'carol-original');
    }
    my $stale = Data::Shared->open($dir);
    is $stale->get('/users/alice/k'), 'alice-original', 'the worker reads the original store';
    is $stale->get('/users/carol/k'), 'carol-original', 'and evicts the first child';

    {   # the documented producer sequence, then a fresh store at the same path
        my $coord = Data::Shared->open($dir);
        $coord->freeze_all;
        $coord->unlink_all;
        my $fresh = Data::Shared->new($dir);
        $fresh->mount('users', $spec);
        $fresh->set('/users/dave/k', 'dave-new-store');
    }

    ok !eval { $stale->get('/users/alice/k'); 1 }, 'the stale worker is refused, not served';
    # The storage belongs to a newer incarnation, which is a different state
    # from this instance's own teardown and says so.
    like $@, qr/belongs to a newer instance/, 'and told why';
    ok !eval { $stale->set('/users/alice/k', 'from-stale'); 1 }, 'and cannot write either';

    my $check = Data::Shared->open($dir);
    is $check->get('/users/dave/k'), 'dave-new-store', "the new store's data is untouched";
    is_deeply [$check->children('/users')], ['dave'], 'and it has only its own child';
};

# A read-only root takes no composite lock, so checking identity only inside
# the locked section left exactly the readers of a shipped store -- which
# cannot write, and so cannot be warned by anything else -- being served
# another incarnation's data under their own addresses.
subtest 'a stale read-only composite cannot attach to a recreated store' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $spec = { spec => 'hashmap:ss', args => [100],
                 child => { spec => 'hashmap:ss', args => [100] }, cache_size => 1 };
    my $maker = Data::Shared->new($dir);
    eval { $maker->mount('users', $spec); 1 } or plan skip_all => "composite unavailable: $@";
    $maker->set('/users/alice/k', 'alice-original');
    $maker->set('/users/carol/k', 'carol-original');
    $maker->freeze_all;

    my $ro = Data::Shared->open_readonly($dir, strict => 1);
    is $ro->get('/users/alice/k'), 'alice-original', 'the shipped store reads';
    is $ro->get('/users/carol/k'), 'carol-original', 'and the first child is evicted';

    $maker->unlink_all;                         # the producer tears its own store down
    my $fresh = Data::Shared->new($dir);
    $fresh->mount('users', $spec);
    $fresh->set('/users/dave/k', 'dave-new-store');
    $fresh->freeze_all;

    ok !eval { $ro->get('/users/alice/k'); 1 }, 'the stale reader is refused';
    like $@, qr/belongs to a newer instance/, 'and told why';
    # Parenthesised: `is Data::Shared->...` parses as a method call on the
    # class name, not as a call to is().
    my $fresh_reader = Data::Shared->open_readonly($dir);
    is $fresh_reader->get('/users/dave/k'), 'dave-new-store',
        'a fresh reader still sees the new store';
};

# The instance check is check-then-open, so removing a composite's directory
# without taking its lock could drop it between a worker's check and its child
# open -- and the worker then attached to whatever appeared at the same child
# path. Teardown waits for the lock now, which lets the worker finish against
# the old instance as the POD allows.
# A recreated store restarts its revision, so the same configuration
# reproduces the same manifest bytes and a stale root's revision check passes.
# Letting a teardown run against a dead instance -- which it must, to finish
# its own -- also let it run against a SUCCESSOR's, and remove its storage.
subtest 'a stale root cannot tear down its successor' => sub {
    my $base = tempdir(CLEANUP => 1);
    my $dir = "$base/store";
    my $spec = ['hashmap:ss', 100, ['hashmap:ss', 100]];
    my $stale = Data::Shared->new($dir);
    eval { $stale->mount('users', $spec); 1 } or plan skip_all => "composite unavailable: $@";
    $stale->set('/users/alice/k', 'original');

    Data::Shared->open($dir)->unlink_all;
    my $fresh = Data::Shared->new($dir);
    $fresh->mount('users', $spec);
    $fresh->set('/users/bob/k', 'replacement');

    ok !eval { $stale->unlink_all; 1 }, "the stale root's teardown is refused";
    like $@, qr/belongs to a newer instance/, 'because the storage is not its own';
    ok -d "$dir/.children/users", "the replacement's children survive";
    undef $fresh;
    my $check = Data::Shared->open($dir);
    is $check->get('/users/bob/k'), 'replacement', 'and its data is intact';
};

# The sweep opened each lock '+<', so a read-only lock file -- which the
# composite's own read fallback expressly supports -- made it skip the lock and
# remove the directory while a worker held it.
subtest 'teardown respects a read-only composite lock' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    eval { $root->mount('users', ['hashmap:ss', 100, ['hashmap:ss', 100]]); 1 }
        or plan skip_all => "composite unavailable: $@";
    $root->set('/users/alice/k', 'v');
    my $lockfile = "$dir/.children/users/.lock";
    chmod 0400, $lockfile or die $!;

    pipe my $held_r, my $held_w or die $!;
    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        close $held_r;
        my $fh;
        my $ok = CORE::open($fh, '<', $lockfile) && flock $fh, Fcntl::LOCK_EX();
        syswrite $held_w, $ok ? "held\n" : "failed\n";
        select undef, undef, undef, 1.5;
        POSIX::_exit($ok ? 0 : 1);
    }
    close $held_w;
    is scalar <$held_r>, "held\n", 'a worker holds the read-only lock';
    my $start = Time::HiRes::time();
    $root->unmount('users');
    $root->unlink_all;
    my $waited = Time::HiRes::time() - $start;
    waitpid $pid, 0;
    cmp_ok $waited, '>', 1, 'the teardown waited for it';
    ok !-d "$dir/.children/users", 'and then removed the directory';
};

subtest 'teardown waits for a composite lock it does not hold' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    eval { $root->mount('users', ['hashmap:ss', 100, ['hashmap:ss', 100]]); 1 }
        or plan skip_all => "composite unavailable: $@";
    $root->set('/users/alice/k', 'v');
    my $lockfile = "$dir/.children/users/.lock";
    ok -e $lockfile, 'the composite has its own lock';

    pipe my $held_r, my $held_w or die $!;
    my $pid = fork;
    plan skip_all => 'cannot fork' unless defined $pid;
    unless ($pid) {
        close $held_r;
        my $fh;
        my $ok = CORE::open($fh, '+<', $lockfile) && flock $fh, Fcntl::LOCK_EX();
        syswrite $held_w, $ok ? "held\n" : "failed\n";
        select undef, undef, undef, 1.5;
        POSIX::_exit($ok ? 0 : 1);
    }
    close $held_w;
    my $ack = <$held_r>;
    is $ack, "held\n", 'a worker holds it';

    my $start = Time::HiRes::time();
    $root->unmount('users');
    $root->unlink_all;
    my $waited = Time::HiRes::time() - $start;
    waitpid $pid, 0;
    is $?, 0, 'the worker kept the lock for its whole hold';
    cmp_ok $waited, '>', 1, 'the teardown waited for it rather than removing underneath';
    ok !-d "$dir/.children/users", 'and then removed the directory';
};

done_testing;
