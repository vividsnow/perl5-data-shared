use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_set shared_get shared_compile);

my $probe = Data::Shared->new;
eval { $probe->mount('p', ['hashmap:ss', 8, ['hashmap:ss', 8]]); 1 }
    or plan skip_all => "composite backends unavailable: $@";

my $root = Data::Shared->new(tempdir(CLEANUP => 1));
my $node = $root->mount('users', ['hashmap:ss', 64, ['hashmap:ss', 8]]);
shared_set($root, '/users/alice/name', 'A');

# call() at a composite node used to answer from the parent leaf, so the
# composite's own lifecycle methods were unreachable or half-applied.
my $stats = $node->call('stats');
ok exists $stats->{children}, 'stats comes from the composite, not the parent leaf';
is $stats->{class}, 'Data::Shared::Composite', 'and reports the composite class';
ok defined $node->call('sync'), 'sync reaches the composite';

# children/handle take a relative path, which they silently ignored.
is_deeply [$root->node('/users')->children], ['alice'], 'children at the node';
my $h = $root->node('/users')->handle('/alice');
ok !$h->isa('Data::Shared::Node'), 'handle("/alice") descends to the child leaf'
    or diag ref $h;

# A Node is absolute; appending one produced /users/users/alice.
my $deep = $root->node('/users');
ok !eval { $deep->node($root->node('/users/alice')); 1 }, 'a Node is not a relative path';
is $deep->node(shared_compile('/alice'))->path, '/users/alice', 'a compiled path is relative';

# An explicit undef must not silently mean "this node's whole subtree".
ok !eval { $deep->delete(undef); 1 }, 'delete(undef) croaks';
is $root->node('/users')->exists('/alice'), 1, 'and deleted nothing';

# Croaks blame the caller, not Node.pm.
eval { $root->node('/nomount')->get('/x') };
like $@, qr/\Q$0\E/, 'a Node croak reports the caller file';

# freeze_all is idempotent.
my $flat = Data::Shared->new(tempdir(CLEANUP => 1));
$flat->mount('c', 'hashmap:ss', undef, 64);
is $flat->freeze_all, 1, 'freeze_all freezes the one mount';
# `ok defined` passed on a second 1, which would mean it froze again.
is $flat->freeze_all, 0, 'a second freeze_all finds nothing left to freeze';
ok $flat->frozen, 'and the root reports itself frozen';

# An omitted argument means this node; an explicit undef means the caller
# computed one and got nothing, which every other tier refuses. Only delete
# said so, so a cursor handed an undef silently read -- or OVERWROTE -- its own
# address instead.
subtest 'an explicit undef relative path is refused by every verb' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = Data::Shared->new($dir);
    eval { $r->mount('m', 'hashmap:ss', undef, 64); 1 }
        or plan skip_all => "hashmap unavailable: $@";
    shared_set($r, '/m/k', 'kept');
    my $cursor = $r->node('/m/k');

    for my $verb (qw(get set exists incr delete push pop)) {
        ok !eval { $cursor->$verb(undef, 'CLOBBERED'); 1 }, "$verb refuses an undef path";
        like $@, qr/node \Q$verb\E: undef relative path/, "$verb names itself";
    }
    # call_at exists to address somewhere else, so it is the one that must not
    # take an undef for this node -- and it was the one verb that did.
    ok !eval { $cursor->call_at(undef, 'exists', 'k'); 1 }, 'call_at refuses one too';
    like $@, qr/node call_at: undef relative path/, 'call_at names itself';
    ok eval { $r->node('/m')->call('exists', 'k'); 1 },
        'call still addresses the node it is on' or diag $@;
    is shared_get($r, '/m/k'), 'kept', 'the value the cursor addresses is untouched';

    # The documented ways to mean "this node" still work.
    is $cursor->get, 'kept', 'an omitted path still reads this node';
    is $cursor->get(''), 'kept', "and so does ''";
    ok eval { $cursor->set('', 'new'); 1 }, "a write through '' is allowed" or diag $@;
    is shared_get($r, '/m/k'), 'new', 'and lands on this node';
};

# Only call_at's refusal was tested. What it exists to do -- reach a method at
# an address below the cursor -- was asserted nowhere, in any tier.
subtest 'call_at reaches a method at a relative address' => sub {
    my $r = Data::Shared->new(tempdir(CLEANUP => 1));
    eval { $r->mount('m', 'hashmap:ss', undef, 64); 1 }
        or plan skip_all => "hashmap unavailable: $@";
    shared_set($r, '/m/k', 'v');
    my $root_cursor = $r->node('/m');
    is $root_cursor->call_at('', 'exists', 'k'), 1, "call_at '' is the mount itself";
    is $root_cursor->call_at('k', 'exists'), 1, 'call_at descends to the leaf address';
    is $r->node('/')->call_at('m', 'exists', 'k'), 1, 'and from a cursor above it';
    ok !eval { $root_cursor->call_at('k', 'no_such_method'); 1 },
        'an absent method at a relative address croaks';
    like $@, qr/has no method 'no_such_method'/, 'and names the method';
};

done_testing;
