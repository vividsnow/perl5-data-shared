use strict;
use warnings;
use Test::More;
use Data::Shared qw(shared_push shared_pop shared_call shared_get);

subtest 'queue Int' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('jobs', 'queue:int', undef, 1024) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/jobs', 42);
    shared_push($r, '/jobs', 43);
    is shared_pop($r, '/jobs'), 42, 'fifo 1';
    is shared_pop($r, '/jobs'), 43, 'fifo 2';
    is shared_call($r, '/jobs', 'size'), 0, 'size via call';
    ok !eval { shared_get($r, '/jobs'); 1 }, 'queue get croaks honestly';
    like $@, qr/shared_push\/shared_pop or shared_call/, 'guidance';
};

subtest 'stack Str' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('s', 'stack:str', undef, 50, 256) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/s', 'hello');
    shared_push($r, '/s', 'world');
    is shared_pop($r, '/s'), 'world', 'lifo 1';
    is shared_pop($r, '/s'), 'hello', 'lifo 2';
};

subtest 'deque Int' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('dq', 'deque:int', undef, 100) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/dq', 1);
    shared_push($r, '/dq', 2);
    shared_call($r, '/dq', 'push_front', 0);
    is shared_pop($r, '/dq'), 0, 'pop_front after push sugar';
};

subtest 'heap priority' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('tasks', 'heap', undef, 100) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/tasks', 3, 300);
    shared_push($r, '/tasks', 1, 100);
    my ($pri, $val) = shared_pop($r, '/tasks');
    is $pri, 1, 'lowest priority first';
    is $val, 100, 'value';
};

subtest 'log append only' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('audit', 'log', undef, 100000) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/audit', 'first');
    is shared_call($r, '/audit', 'entry_count'), 1, 'entry_count';
    ok !eval { shared_pop($r, '/audit'); 1 }, 'log pop croaks';
};

subtest 'ringbuffer' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('ring', 'ringbuffer:int', undef, 100) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    shared_push($r, '/ring', 42);
    shared_push($r, '/ring', 99);
    is shared_get($r, '/ring'), 99, 'latest via get without index';
    my $seq = shared_call($r, '/ring', 'write', 777);
    is shared_get($r, "/ring/$seq"), 777, 'read_seq via get with index';
};

subtest 'pubsub publish' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('ev', 'pubsub:int', undef, 1024) };
    if ($@) { plan skip_all => "backend unavailable: $@"; return }
    my $sub = shared_call($r, '/ev', 'subscribe');
    shared_push($r, '/ev', 42);
    is $sub->poll, 42, 'subscriber sees published value';
    ok !eval { shared_pop($r, '/ev'); 1 }, 'pubsub pop croaks (needs subscriber)';
};

done_testing;
