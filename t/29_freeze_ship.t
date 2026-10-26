use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists shared_push);

my $probe = Data::Shared->new(tempdir(CLEANUP => 1));
eval { $probe->mount('p', ['hashmap:ss', 64, ['hashmap:ss', 8], { max_children => 64 }]); 1 }
    or plan skip_all => "composite backends unavailable: $@";

sub store {
    my (%o) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('cache', 'hashmap:ii', undef, 64);
    $root->mount('users', ['hashmap:ss', 256, ['hashmap:ss', 8],
                           { max_children => 256, %{ $o{opts} || {} } }]);
    shared_set($root, "/users/u$_/k", 1) for 1 .. ($o{children} || 1);
    return ($root, $dir);
}

# A child outside the open-child cache has to be reopened to be frozen, and a
# frozen file refuses the writable constructor. The walk used to croak on it,
# leaving the store sealed in part: openable in neither mode.
subtest 'freeze_all is idempotent past the child cache' => sub {
    my ($root) = store(children => 40);                 # default cache_size 32
    cmp_ok $root->freeze_all, '>=', 42, 'first pass seals children, parent and index';
    is $root->freeze_all, 0, 'second pass seals nothing and does not croak';
    is $root->freeze_all, 0, 'and stays idempotent';
};

subtest 'a child frozen directly does not block the walk' => sub {
    my ($root, $dir) = store(children => 1, opts => { cache_size => 1 });
    $root->node('/users/u1')->call('freeze');
    shared_set($root, '/users/u2/k', 1);                # evicts u1
    cmp_ok $root->freeze_all, '>=', 1, 'freeze_all completes over the frozen child';
    ok $root->frozen, 'and reports the store sealed';
    undef $root;
    my $ro = Data::Shared->open_readonly($dir);
    is shared_get($ro, '/users/u1/k'), 1, 'shipped store reads the frozen child';
};

# Sealing does not stop the producer reading its own store. A child that had
# fallen out of the open-child cache was reopened with the writable
# constructor, which a sealed file refuses, so a read croaked -- and which
# children did depended on what the cache happened to hold when freeze_all ran.
subtest 'the sealing root can still read every child' => sub {
    my ($root) = store(children => 5, opts => { cache_size => 2 });
    $root->freeze_all;
    for my $i (1 .. 5) {
        is shared_get($root, "/users/u$i/k"), 1, "u$i reads after sealing";
        is shared_exists($root, "/users/u$i/k"), 1, "u$i exists answers 1, not a croak";
    }
    # And the contract that keeps this scoped to children.
    my $dir = tempdir(CLEANUP => 1);
    {
        my $producer = Data::Shared->new($dir);
        $producer->mount('u', ['hashmap:ss', 64, ['hashmap:ss', 8]]);
        shared_set($producer, '/u/a/k', 1);
        $producer->freeze_all;
    }
    ok !eval { Data::Shared->open($dir); 1 }, 'a writable reopen of a sealed store is still refused';
    ok eval { Data::Shared->open_readonly($dir); 1 }, 'and a read-only one works';
};

subtest 'frozen reports whether the store can be shipped' => sub {
    my ($root) = store(children => 2);
    ok !$root->frozen, 'not frozen before';
    $root->freeze_all;
    ok $root->frozen, 'frozen after';

    my $mixed = Data::Shared->new(tempdir(CLEANUP => 1));
    $mixed->mount('cache', 'hashmap:ii', undef, 64);
    if (eval { $mixed->mount('jobs', 'queue:int', undef, 8); 1 }) {
        $mixed->freeze_all;
        ok !$mixed->frozen, 'a store with an unfreezable mount is never shippable';
    }
    my $empty = Data::Shared->new(tempdir(CLEANUP => 1));
    ok !$empty->frozen, 'an empty store is not shippable';

    # freeze_all's 0 is ambiguous on its own: already sealed, or nothing
    # sealable. frozen is what tells those apart.
    my ($sealed) = store(children => 1);
    $sealed->freeze_all;
    is $sealed->freeze_all, 0, 'sealed store seals nothing more';
    ok $sealed->frozen, 'and reports sealed';
};

# Hash order made the set of sealed mounts differ from run to run, and a store
# sealed in part opens in neither mode.
subtest 'freeze_all seals in mount order' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount("m$_", 'hashmap:ii', undef, 16) for 1 .. 6;
    shared_set($root, "/m$_/1", 1) for 1 .. 6;
    my $target = $root->{mounts}{m4}{handle};
    no warnings 'redefine';
    my $orig = \&Data::HashMap::Shared::II::freeze;
    local *Data::HashMap::Shared::II::freeze = sub {
        die "injected failure\n" if $_[0] == $target;
        $orig->(@_);
    };
    ok !eval { $root->freeze_all; 1 }, 'a failing mount aborts the pass';
    my @state = map { $root->{mounts}{"m$_"}{handle}->frozen ? 1 : 0 } 1 .. 6;
    is_deeply \@state, [1, 1, 1, 0, 0, 0], 'everything before it is sealed, nothing after';
};

# The counter rebuild must not run against a sealed index: it cannot take the
# write, and a count is derived from the addresses when it is absent. Entering
# the lifecycle lock clears a pending marker while the index is still writable,
# so this state needs the index handle to reach.
subtest 'a sealed index with a pending marker does not break the walk' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('org', ['hashmap:ss', 64, ['hashmap:ss', 64, ['hashmap:ss', 8]]]);
    shared_set($root, '/org/a/b/k', 1);
    my $inner = $root->{mounts}{org}{composite}{cache}{0}{comp};
    $inner->{index}->put('p:', 1);
    $inner->{index}->freeze;
    cmp_ok $root->freeze_all, '>=', 1, 'freeze_all completes';
    ok $root->frozen, 'and the store is sealed';
    undef $root;
    my $ro = Data::Shared->open_readonly($dir);
    is shared_get($ro, '/org/a/b/k'), 1, 'and ships';
};

# The same guard, on a composite that is sealed but NOT shippable. The rebuild
# must ask whether the index can take a write, which is not the same question
# as whether the subtree can be shipped read-only.
subtest 'the rebuild guard does not depend on shippability' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    plan skip_all => 'queue backend unavailable'
        unless eval { $root->mount('q', ['hashmap:ss', 64, ['queue:int', 8]]); 1 };
    shared_push($root, '/q/a', 42);     # not node->push(42): that reads 42 as a path
    my $comp = $root->{mounts}{q}{composite};
    $comp->{index}->put('p:', 1);
    $comp->{index}->freeze;
    ok !$comp->frozen, 'the subtree is not shippable, because a level is not';
    ok defined eval { $root->freeze_all }, 'but freeze_all still completes';
};

# sync_all is documented as applying to every mount; for a composite that is
# the whole subtree, not just the children that happen to be open.
subtest 'sync covers every registered child' => sub {
    my $calls = 0;
    my $orig = \&Data::HashMap::Shared::SS::sync;
    no warnings 'redefine';
    local *Data::HashMap::Shared::SS::sync = sub { $calls++; $orig->(@_) };

    my ($root) = store(children => 40);                 # default cache_size 32
    my $stats = $root->stats->{users};
    is $stats->{children}, 40, '40 children registered';
    cmp_ok $stats->{open}, '<', 40, 'and fewer than that open';
    $calls = 0;
    my $n = $root->node('/users')->call('sync');
    is $n, 42, 'sync reports children plus parent and index';
    is $calls, 42, 'and really flushed that many';
};

done_testing;
