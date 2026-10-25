use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Data::Shared qw(shared_compile sharedc_get);

eval { require Data::HashMap::Shared::SS; require Data::Sync::Shared::Semaphore; 1 }
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
    is select($readable, undef, undef, 0.1), 0, 'deletion has not completed while constructor holds the lock';
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
    $root->node('/users/a')->call('freeze');
    $root->set('/users/c/d/key', 'other');
    $root->delete('/users/a');
    is $old_index->get('x:'), 1, 'old mappings see retirement after cache eviction';
    ok !-d $root->dir . '/.children/users/child-0', 'old directory removed';
    $root->set('/users/a/b/key', 'new');
    is $root->get('/users/a/b/key'), 'new', 'fresh nested instance remains usable';
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

done_testing;
