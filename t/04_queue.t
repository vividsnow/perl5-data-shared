use strict;
use warnings;
use Test::More;
use Data::Shared qw(shared_push shared_pop shared_call shared_get
                    shared_compile sharedc_push sharedc_get);

# Named for the skip, as t/13's mount_or_skip is: plan skip_all inside a
# subtest ends it, so this does not return when the backend is missing.
sub root_or_skip {
    my ($name, @spec) = @_;
    my $root = Data::Shared->new;
    eval { $root->mount($name, @spec) };
    plan skip_all => "backend unavailable: $@" if $@;
    return $root;
}

subtest 'queue Int' => sub {
    my $r = root_or_skip('jobs', 'queue:int', undef, 1024);
    shared_push($r, '/jobs', 42);
    shared_push($r, '/jobs', 43);
    is shared_pop($r, '/jobs'), 42, 'fifo 1';
    is shared_pop($r, '/jobs'), 43, 'fifo 2';
    is shared_call($r, '/jobs', 'size'), 0, 'size via call';
    ok !eval { shared_get($r, '/jobs'); 1 }, 'queue get croaks honestly';
    like $@, qr/shared_push\/shared_pop or shared_call/, 'guidance';
};

subtest 'stack Str' => sub {
    my $r = root_or_skip('s', 'stack:str', undef, 50, 256);
    shared_push($r, '/s', 'hello');
    shared_push($r, '/s', 'world');
    is shared_pop($r, '/s'), 'world', 'lifo 1';
    is shared_pop($r, '/s'), 'hello', 'lifo 2';
};

subtest 'deque Int' => sub {
    my $r = root_or_skip('dq', 'deque:int', undef, 100);
    shared_push($r, '/dq', 1);
    shared_push($r, '/dq', 2);
    shared_call($r, '/dq', 'push_front', 0);
    is shared_pop($r, '/dq'), 0, 'pop_front after push sugar';
};

subtest 'heap priority' => sub {
    my $r = root_or_skip('tasks', 'heap', undef, 100);
    shared_push($r, '/tasks', 3, 300);
    shared_push($r, '/tasks', 1, 100);
    my ($pri, $val) = shared_pop($r, '/tasks');
    is $pri, 1, 'lowest priority first';
    is $val, 100, 'value';
};

subtest 'log append only' => sub {
    my $r = root_or_skip('audit', 'log', undef, 100000);
    shared_push($r, '/audit', 'first');
    is shared_call($r, '/audit', 'entry_count'), 1, 'entry_count';
    ok !eval { shared_pop($r, '/audit'); 1 }, 'log pop croaks';
};

subtest 'ringbuffer' => sub {
    my $r = root_or_skip('ring', 'ringbuffer:int', undef, 100);
    shared_push($r, '/ring', 42);
    shared_push($r, '/ring', 99);
    is shared_get($r, '/ring'), 99, 'latest via get without index';
    my $seq = shared_call($r, '/ring', 'write', 777);
    is shared_get($r, "/ring/$seq"), 777, 'read_seq via get with index';
};

subtest 'pubsub publish' => sub {
    my $r = root_or_skip('ev', 'pubsub:int', undef, 1024);
    my $sub = shared_call($r, '/ev', 'subscribe');
    shared_push($r, '/ev', 42);
    is $sub->poll, 42, 'subscriber sees published value';
    ok !eval { shared_pop($r, '/ev'); 1 }, 'pubsub pop croaks (needs subscriber)';
};

# A remainder was forwarded into the native call as a leading argument, so a
# push to '/jobs/5' inserted with priority 5 on a heap -- the wrong path
# succeeded -- and on the others it surfaced as the backend's own arity error
# blaming its API. The map, set and sketch families already refuse this shape.
subtest 'a queue path takes no key component' => sub {
    my $root = Data::Shared->new;
    my @mounted;
    for my $spec (['queue', 'queue:int', 1024], ['stack', 'stack:int', 1024],
                  ['heap', 'heap', 1024], ['log', 'log', 1024]) {
        my ($name, $type, @args) = @$spec;
        unless (eval { $root->mount($name, $type, undef, @args); 1 }) {
            # One survivor used to satisfy the skip below, so the path limit
            # could break for three of the four families with nothing failing.
            fail "mounting '$type' failed: $@"
                unless $@ =~ /is not available; install the|Can't locate \S+\.pm/;
            next;
        }
        push @mounted, [$name, $type];
    }
    plan skip_all => 'no queue-family backend available' unless @mounted;
    for my $m (@mounted) {
        my ($name, $type) = @$m;
        ok !eval { shared_push($root, "/$name/5", 42); 1 }, "$type refuses a push with a component";
        like $@, qr/\Qpath too long\E/, "$type says the path is too long";
        ok !eval { shared_pop($root, "/$name/5"); 1 }, "$type refuses a pop with a component"
            if $type ne 'log';
    }
    # ringbuffer's get is the one verb in the family that does read a
    # component, so it is the boundary the limit must not cross.
    my $rb_ok = eval { $root->mount('rb', 'ringbuffer', undef, 64); 1 };
    my $rb_why = $@;
    if ($rb_ok) {
        shared_push($root, '/rb', 11);
        is shared_get($root, '/rb/0'), 11, 'a ringbuffer get reads its sequence number';
        is sharedc_get($root, shared_compile('/rb/0')), 11, 'and through a compiled path';
        ok !eval { shared_get($root, '/rb/0/1'); 1 }, 'but two components are refused';
        ok !eval { shared_push($root, '/rb/5', 9); 1 }, 'and a keyed push is still refused';
    }
    else {
        like $rb_why, qr/is not available/, 'the ringbuffer case needs an absent backend'
            or diag $rb_why;
    }

    # The compiled tier resolves its path once, so it must refuse at bind time.
    # Split: one eval around both calls passed when the refusal came from the
    # push instead, which is the regression this is here to catch.
    my $compiled = shared_compile("/$mounted[0][0]/5");
    ok $compiled, 'compiling an over-long queue path is allowed';
    ok !eval { sharedc_push($root, $compiled, 42); 1 },
        'the compiled tier refuses it at bind time';
    like $@, qr/\Qpath too long\E/, 'with the same reason as the string tier';

    # A composite child address is not a remainder: it is consumed by the
    # composite before the leaf ever sees it. This is the guard against the
    # limit breaking the composite path, so whether it ran is asserted rather
    # than left to a bare "if" that would hide its absence.
    my $comp = Data::Shared->new;
    my $composite_ok = eval { $comp->mount('q', ['hashmap:ss', 64, ['queue:int', 8]]); 1 };
    my $why = $@;
    if ($composite_ok) {
        ok eval { shared_push($comp, '/q/a', 42); 1 }, 'a push into a composite child still works';
        is shared_pop($comp, '/q/a'), 42, 'and pops back';
    }
    else {
        # Only a missing backend may skip this; any other failure is a failure.
        like $why, qr/is not available/, 'the composite case needs an absent backend'
            or diag $why;
    }
};

done_testing;
