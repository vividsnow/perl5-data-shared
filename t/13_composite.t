use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_delete shared_exists shared_call
                    shared_compile sharedc_get sharedc_exists shared_node shared_children);

sub mount_or_skip {
    my ($root, $name, @spec) = @_;
    my $h = eval { $root->mount($name, @spec) };
    if (!$h) { plan skip_all => "backend unavailable: $@"; }
    return $h;
}

subtest 'hashmap:ss of bloomfilter' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'users', ['hashmap:ss', 1000, ['bloomfilter', 10000, 0.01]]);
    ok $r->mount_info('users')->{composite}, 'composite flag';
    is_deeply [$r->children('/users')], [], 'no children initially';
    is shared_get($r, '/users/alice/event-1'), undef, 'missing deep get undef';
    is_deeply [$r->children('/users')], [], 'read does not create';
    is shared_exists($r, '/users/alice'), 0, 'missing child exists 0';

    shared_set($r, '/users/alice/event-42', 1);
    is shared_exists($r, '/users/alice'), 1, 'child exists after write';
    is shared_exists($r, '/users/alice/event-42'), 1, 'deep exists';
    is shared_exists($r, '/users/alice/event-99'), 0, 'deep absent';
    is_deeply [$r->children('/users')], ['alice'], 'children lists alice';
    is_deeply [shared_children($r, '/users')], ['alice'], 'shared_children';

    my $node = shared_get($r, '/users/alice');
    isa_ok $node, 'Data::Shared::Node', 'intermediate get is node';
    is $node->path, '/users/alice', 'node path';
    is $node->call('count'), 1, 'node call count';
    is $node->exists('/event-42'), 1, 'node relative exists';
    is $r->node('/users/alice')->call('count'), 1, 'root node call';
    isa_ok shared_node($r, '/users'), 'Data::Shared::Node', 'shared_node';
    is ref($r->handle('/users/alice')), 'Data::BloomFilter::Shared', 'handle is child leaf';
    isa_ok $r->handle('/users'), 'Data::Shared::Node', 'handle of composite is node';

    shared_set($r, '/users/bob/event-1', 1);
    is_deeply [$r->children('/users')], ['alice', 'bob'], 'two children sorted';
    ok !eval { shared_set($r, '/users/alice', 1); 1 }, 'set at hashmap child croaks';
    like $@, qr/cannot set a composite child/, 'set child error';
    shared_delete($r, '/users/alice');
    is shared_exists($r, '/users/alice'), 0, 'subtree deleted';
    is shared_exists($r, '/users/alice/event-42'), 0, 'subtree deep gone';
    is_deeply [$r->children('/users')], ['bob'], 'children after delete';
    is shared_delete($r, '/users/nobody'), undef, 'delete missing subtree undef';
};

subtest 'hashmap:ii of hashmap:ss with int address validation' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'byid', ['hashmap:ii', 1000, ['hashmap:ss', 1000]]);
    shared_set($r, '/byid/42/name', 'alice');
    is shared_get($r, '/byid/42/name'), 'alice', 'deep map get';
    is_deeply [$r->children('/byid')], ['42'], 'int child listed as string';
    shared_set($r, '/byid/10/name', 'ten');
    shared_set($r, '/byid/2/name', 'two');
    is_deeply [$r->children('/byid')], ['2', '10', '42'], 'int children sorted numerically';
    ok !eval { shared_set($r, '/byid/alice/name', 'x'); 1 }, 'non-int address croaks on write';
    like $@, qr/invalid composite address/, 'address error';
    is shared_get($r, '/byid/alice/name'), undef, 'non-int read is undef';
    is shared_exists($r, '/byid/alice'), 0, 'non-int exists 0';
};

subtest 'sortedset:strings of bloomfilter keeps score' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'leaders', ['sortedset:strings', { max => 1000 }, ['bloomfilter', 10000, 0.01]]);
    shared_set($r, '/leaders/alice', 1500);
    is shared_get($r, '/leaders/alice'), 1500, 'score at child path';
    is_deeply [$r->children('/leaders')], ['alice'], 'score set registers child';
    shared_set($r, '/leaders/alice/event-9', 1);
    is shared_exists($r, '/leaders/alice/event-9'), 1, 'child event';
    is shared_get($r, '/leaders/alice'), 1500, 'score preserved after child write';
    is shared_call($r, '/leaders', 'child_count'), 1, 'child_count via call';
    my @kids = shared_call($r, '/leaders', 'children');
    is_deeply \@kids, ['alice'], 'children via call';
    shared_delete($r, '/leaders/alice');
    is shared_get($r, '/leaders/alice'), undef, 'score gone after subtree delete';
};

subtest 'sortedset int of roaringbitmap' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'board', ['sortedset', 1000, ['roaringbitmap', 256]]);
    shared_set($r, '/board/42/70000', 1);
    is shared_exists($r, '/board/42/70000'), 1, 'roaring child member';
    is shared_get($r, '/board/42'), 0, 'auto score 0';
    shared_set($r, '/board/42', 900);
    is shared_get($r, '/board/42'), 900, 'score set after child exists';
};

subtest 'three levels: hashmap of kdtree of hashmap' => sub {
    if (!eval { require Data::KDTree::Shared; 1 }) { plan skip_all => 'kdtree backend unavailable'; return }
    my $r = Data::Shared->new;
    my $h = eval { $r->mount('atlas', ['hashmap:ss', 1000, ['kdtree', 2, 1000, ['hashmap:ss', 1000]]]) };
    if (!$h) { plan skip_all => "backend unavailable: $@"; return }
    my $eu = $r->node('/atlas/europe');
    $eu->call('add', [10.5, 20.5], 42);
    shared_set($r, '/atlas/europe/42/name', 'place-42');
    is shared_get($r, '/atlas/europe/42/name'), 'place-42', 'three level get';
    is_deeply [$r->children('/atlas')], ['europe'], 'level 1 children';
    is_deeply [$r->children('/atlas/europe')], ['42'], 'level 2 children';
    is $eu->call('nearest', [10.0, 20.0])->{id}, 42, 'node call on kdtree child';
    shared_delete($r, '/atlas/europe');
    is shared_get($r, '/atlas/europe/42/name'), undef, 'mid subtree delete clears deep';
};

subtest 'invalid composite parents rejected' => sub {
    my $r = Data::Shared->new;
    ok !eval { $r->mount('bad1', ['bloomfilter', 1000, 0.01, ['hashmap:ss', 100]]); 1 }, 'bloom parent croaks';
    like $@, qr/cannot be a composite parent/, 'bloom parent error';
    ok !eval { $r->mount('bad2', ['queue:int', 100, ['hashmap:ss', 100]]); 1 }, 'queue parent croaks';
    ok !eval { $r->mount('bad3', ['hashmap:ss', 100, ['nosuchthing', 100]]); 1 }, 'unknown child croaks';
    ok !eval { $r->mount('bad4', ['hashmap:ss', 100, ['bloomfilter', 1000, 0.01], { max_children => 0 }]); 1 }, 'max_children 0 croaks on write or mount';
    ok !eval { $r->children('/users'); 1 }, 'children on missing mount croaks';
    my $r2 = Data::Shared->new;
    SKIP: {
        my $handle = eval { $r2->mount('plain', 'hashmap:ii', undef, 100) };
        skip "hashmap backend unavailable: $@", 2 unless $handle;
        ok !eval { $r2->children('/plain'); 1 }, 'children on plain mount croaks';
        like $@, qr/not composite/, 'not composite error';
    }
};

subtest 'child budget and eviction with file storage' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = Data::Shared->new($dir);
    my $h = eval { $r->mount('users', { spec => 'hashmap:ss', args => [1000],
        child => { spec => 'bloomfilter', args => [10000, 0.01] }, max_children => 2, cache_size => 1 }) };
    if (!$h) { plan skip_all => "backend unavailable: $@"; return }
    shared_set($r, '/users/a/e1', 1);
    shared_set($r, '/users/b/e2', 1);
    is shared_exists($r, '/users/a/e1'), 1, 'evicted child a still readable from storage';
    is shared_exists($r, '/users/b/e2'), 1, 'child b readable';
    ok !eval { shared_set($r, '/users/c/e3', 1); 1 }, 'third child exceeds budget';
    like $@, qr/child limit exceeded/, 'budget error';
    is_deeply [$r->children('/users')], ['a', 'b'], 'budget children unchanged';
};

subtest 'persistence across reopen' => sub {
    my $dir = tempdir(CLEANUP => 1);
    {
        my $r = Data::Shared->new($dir);
        my $h = eval { $r->mount('users', ['hashmap:ss', 1000, ['bloomfilter', 10000, 0.01]]) };
        if (!$h) { plan skip_all => "backend unavailable: $@"; return }
        shared_set($r, '/users/alice/event-42', 1);
        ok -d "$dir/.children/users", 'children storage dir';
    }
    my $r = Data::Shared->open($dir);
    is shared_exists($r, '/users/alice/event-42'), 1, 'deep data after reopen';
    is_deeply [$r->children('/users')], ['alice'], 'children after reopen';
    my $stats = $r->stats;
    is $stats->{users}{children}, 1, 'stats children count';
    ok $r->sync_all >= 1, 'sync_all with composite';
};

subtest 'compiled deep paths stay correct across delete' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'users', ['hashmap:ss', 1000, ['hashmap:ss', 1000]]);
    shared_set($r, '/users/bob/name', 'x');
    my $cp = shared_compile('/users/bob/name');
    is sharedc_get($r, $cp), 'x', 'compiled deep get';
    is sharedc_exists($r, $cp), 1, 'compiled deep exists';
    shared_delete($r, '/users/bob/name');
    is sharedc_exists($r, $cp), 0, 'compiled deep after inner delete';
    shared_set($r, '/users/bob/name', 'y');
    is sharedc_get($r, $cp), 'y', 'compiled deep after rewrite';
    shared_delete($r, '/users/bob');
    is sharedc_exists($r, $cp), 0, 'compiled deep after subtree delete';
    shared_set($r, '/users/bob/name', 'z');
    is sharedc_get($r, $cp), 'z', 'compiled deep after recreate';
};

subtest 'graph of hashmap by node id' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'net', ['graph', 100, 500, ['hashmap:ss', 100]]);
    my $a = shared_call($r, '/net', 'add_node', 10);
    shared_set($r, "/net/$a/name", 'node-a');
    is shared_get($r, "/net/$a/name"), 'node-a', 'graph child get';
    is_deeply [$r->children('/net')], ["$a"], 'graph children by id';
};

subtest 'fixed-width int parents reject aliasing addresses' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'm16', ['hashmap:i16s', 100, ['hashmap:ss', 100]]);
    shared_set($r, "/m16/$_/name", "k$_") for -32768, 32767;
    is shared_get($r, '/m16/32767/name'), 'k32767', 'in-range i16 address works';
    for my $bad (70000, 40000, -32769) {
        ok !eval { shared_set($r, "/m16/$bad/name", 'alias'); 1 }, "i16 parent rejects $bad";
    }
    is_deeply [$r->children('/m16')], [-32768, 32767], 'no aliased children';

    $r->mount('m32', ['hashmap:i32s', 100, ['hashmap:ss', 100]]);
    shared_set($r, '/m32/2147483647/name', 'max');
    is shared_get($r, '/m32/2147483647/name'), 'max', 'in-range i32 address works';
    ok !eval { shared_set($r, '/m32/2147483648/name', 'alias'); 1 }, 'i32 parent rejects 2147483648';

    # A plain leaf mount keeps the backend's documented wrapping.
    $r->mount('leaf', 'hashmap:i16s', undef, 100);
    ok eval { shared_set($r, '/leaf/70000', 'wrapped'); 1 }, 'leaf mount still accepts a wrapping key';
};

subtest 'call at a missing child materialises it' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'm', ['hashmap:ss', 100, ['hashmap:ss', 100]]);
    is shared_get($r, '/m/ghost/k'), undef, 'read does not create';
    is shared_exists($r, '/m/ghost'), 0, 'exists does not create';
    is_deeply [$r->children('/m')], [], 'still no children';
    is shared_call($r, '/m/ghost', 'size'), 0, 'read-only call answers';
    is_deeply [$r->children('/m')], ['ghost'], 'the call registered the child';
};

subtest 'id-parents address by integer id' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'net', ['graph', 100, 500, ['hashmap:ss', 100]]);
    shared_set($r, "/net/$_/name", "n$_") for 1, 2, 3, 10, 11, 12;
    is_deeply [$r->children('/net')], [1, 2, 3, 10, 11, 12], 'graph ids list in numeric order';
    for my $bad ('007', "7\n", 'alice', '-0') {
        (my $show = $bad) =~ s/\n/\\n/;
        ok !eval { shared_set($r, "/net/$bad/name", 'phantom'); 1 }, "graph rejects id '$show'";
    }
    is_deeply [$r->children('/net')], [1, 2, 3, 10, 11, 12], 'no phantom children registered';

    if (eval { require Data::KDTree::Shared; 1 }) {
        my $k = Data::Shared->new;
        mount_or_skip($k, 'pts', ['kdtree', 2, 1000, ['hashmap:ss', 100]]);
        shared_set($k, "/pts/$_/name", "p$_") for 1, 2, 10;
        is_deeply [$k->children('/pts')], [1, 2, 10], 'kdtree ids list in numeric order';
        ok !eval { shared_set($k, '/pts/007/name', 'phantom'); 1 }, 'kdtree rejects id 007';
    }
};

subtest 'nested composite: hashmap of sortedset of hashmap' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'org', ['hashmap:ss', 1000, ['sortedset:strings', { max => 1000 }, ['hashmap:ss', 100]]]);
    shared_set($r, '/org/acme/alice/role', 'admin');
    is shared_get($r, '/org/acme/alice/role'), 'admin', 'nested deep get';
    $r->node('/org/acme')->set('/alice', 42);
    is shared_get($r, '/org/acme/alice'), 42, 'nested score via node';
    is shared_get($r, '/org/acme/alice/role'), 'admin', 'role preserved';
};

subtest 'freeze then readonly deep reads' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = Data::Shared->new($dir);
    mount_or_skip($r, 'users', ['hashmap:ss', 1000, ['bloomfilter', 10000, 0.01]]);
    shared_set($r, '/users/alice/event-1', 1);
    $r->freeze_all;
    my $ro = Data::Shared->open_readonly($dir);
    is shared_exists($ro, '/users/alice/event-1'), 1, 'readonly deep exists';
    is_deeply [$ro->children('/users')], ['alice'], 'readonly children';
    ok !eval { shared_set($ro, '/users/bob/event-1', 1); 1 }, 'readonly deep write croaks';
};

subtest 'child write from a second process' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = Data::Shared->new($dir);
    mount_or_skip($r, 'users', ['hashmap:ss', 1000, ['bloomfilter', 10000, 0.01]]);
    my $pid = fork();
    plan skip_all => 'fork not available' unless defined $pid;
    if ($pid == 0) {
        my $c = Data::Shared->open($dir);
        shared_set($c, '/users/childproc/event-1', 1);
        exit(shared_exists($c, '/users/childproc/event-1') ? 0 : 1);
    }
    waitpid $pid, 0;
    is $?, 0, 'child process wrote';
    is shared_exists($r, '/users/childproc/event-1'), 1, 'parent sees child write';
};

subtest 'queue child under hashmap' => sub {
    my $r = Data::Shared->new;
    mount_or_skip($r, 'queues', ['hashmap:ss', 1000, ['queue:int', 100]]);
    $r->push('/queues/alice', 42);
    is $r->pop('/queues/alice'), 42, 'push/pop into child queue';
    is_deeply [$r->children('/queues')], ['alice'], 'queue child registered';
};

done_testing;
