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
ok $flat->freeze_all, 'freeze_all works';
ok defined eval { $flat->freeze_all }, 'freeze_all is idempotent' or diag $@;

done_testing;
