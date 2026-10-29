use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_set);

my $probe = Data::Shared->new;
eval { $probe->mount('p', ['hashmap:ss', 8, ['hashmap:ss', 8], { max_children => 4 }]); 1 }
    or plan skip_all => "composite backends unavailable: $@";

# The child index stores 'a:<addr>' and 'c:<addr>' per child, each taking an
# arena block of next_pow2(2 + length addr). Sized by entry count alone, the
# arena ran out at half of max_children for addresses over 126 bytes, and
# raising max_children did not help because the shortfall is a ratio.
for my $len (126, 200, 254) {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('u', ['hashmap:ss', 40, 0, 0, 0, 40 * 2048,
                       ['hashmap:ss', 8], { max_children => 40 }]);
    my $made = 0;
    for my $i (1 .. 40) {
        my $addr = sprintf '%0*d', $len, $i;
        last unless eval { shared_set($root, "/u/$addr/k", 1); 1 };
        $made++;
    }
    is $made, 40, "all 40 children fit with ${len}-byte addresses";
}

# A hash in the documented child+options position must be options, not silently
# demoted to parent constructor arguments.
{
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    ok !eval { $root->mount('s', ['hashmap:ss', 64, ['hashmap:ss', 8],
                                  { maxchildren => 5 }]); 1 },
        'a misspelled composite option croaks';
    like $@, qr/unknown composite option 'maxchildren'/, 'the croak names the key';
    ok eval { $root->mount('t', ['hashmap:ss', 64, ['hashmap:ss', 8],
                                 { max_children => 5 }]); 1 },
        'the correct option still mounts';
    is $root->mount_info('t')->{composite}, 1, 'and it really is composite';
    # An empty one asks for the defaults. It fell through to the typo branch
    # and croaked naming no key at all: "unknown composite options ''".
    my $empty = eval { $root->mount('e', ['hashmap:ss', 64, ['hashmap:ss', 8], {}]); 1 };
    ok $empty, 'an empty options hash asks for the defaults' or diag $@;
    is eval { $root->mount_info('e')->{composite} }, 1, 'and still mounts a composite'
        if $empty;
}

# The index file is sized from max_children when it is created, so remounting
# the same name with a larger budget published a number the storage could not
# serve: children were refused at a fraction of it, and the refusal quoted the
# published number back.
subtest 'a composite cannot be remounted with a budget its storage cannot serve' => sub {
    my $spec = sub { ['hashmap:ss', 64, ['hashmap:ii', 16], { max_children => $_[0] }] };
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('u', $spec->(3));
    shared_set($root, '/u/alice/5', 1);

    $root->unmount('u');
    ok !eval { $root->mount('u', $spec->(50)); 1 }, 'raising the budget is refused';
    like $@, qr/created for max_children=3 and cannot serve 50/, 'and names both';
    like $@, qr/unmount\(unlink => 1\)/, 'and the way out';

    ok eval { $root->mount('u', $spec->(3)); 1 }, 'the recorded budget still mounts' or diag $@;
    is Data::Shared::shared_get($root, '/u/alice/5'), 1, 'over the same children';
    $root->unmount('u');
    ok eval { $root->mount('u', $spec->(2)); 1 }, 'and so does a smaller one' or diag $@;

    # The storage really does hold what it promises, and the refusal that comes
    # when it is full names the slot table -- the limit that actually binds.
    # The old message printed max_entries, a smaller load-factor figure a put
    # had already sailed past, so it read "entries 32/24".
    my $fresh = Data::Shared->new(tempdir(CLEANUP => 1));
    $fresh->mount('u', $spec->(50));
    my $made = 0;
    for my $i (1 .. 60) {
        last unless eval { shared_set($fresh, "/u/u$i/5", $i); 1 };
        $made++;
    }
    is $made, 50, 'a budget of 50 really holds 50 children';
    like $@, qr/child limit exceeded \(max_children=50\)/, 'and stops on the budget, not the file';
};

# The refusal belongs where the caller named the budget. A nested level is
# reached from a read, so refusing there would take out a store for publishing
# an oversized number; it serves the ceiling its storage really has instead,
# and says that number rather than the published one.
subtest 'a nested level keeps serving the budget its storage was built for' => sub {
    my $spec = sub {
        ['hashmap:ss', 64, ['hashmap:ss', 64, ['hashmap:ii', 16], { max_children => $_[0] }],
         { max_children => 100 }];
    };
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    eval { $root->mount('u', $spec->(3)); 1 } or plan skip_all => "nested composite unavailable: $@";
    shared_set($root, '/u/eu/paris/5', 1);
    $root->unmount('u');
    ok eval { $root->mount('u', $spec->(50)); 1 },
        'raising only a nested budget is not refused at mount' or diag $@;
    is eval { Data::Shared::shared_get($root, '/u/eu/paris/5') }, 1,
        'and a deep read still works' or diag $@;

    my $made = 1;        # paris
    for my $i (1 .. 12) {
        last unless eval { shared_set($root, "/u/eu/city$i/5", $i); 1 };
        $made++;
    }
    is $made, 3, 'the nested level stops at what its index holds';
    like $@, qr/child limit exceeded \(max_children=3\)/,
        'and names that number, not the one the manifest published';
};

# A child is an entry in the parent leaf too, so a parent smaller than the
# budget is the real ceiling. The refusal said only 'cannot register child in
# parent backend', which reads like an internal error and names neither the
# exhausted resource nor the limit -- next to _index_put, which names both.
subtest 'a full parent leaf names itself as the ceiling' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    eval { $root->mount('l', ['sortedset', 4, ['bloomfilter', 10_000, 0.01]]); 1 }
        or plan skip_all => "sortedset-parented composite unavailable: $@";
    my $made = 0;
    for my $i (1 .. 8) {
        last unless eval { shared_set($root, "/l/$i/x", 1); 1 };
        $made++;
    }
    is $made, 4, 'the capacity-4 parent takes four children';
    like $@, qr/in the sortedset parent of 'l'/, 'the refusal names the parent';
    like $@, qr/parent holds 4 of 4/, 'and the resource that ran out';
    like $@, qr/bounds max_children=10000/, 'and the budget it bounds';
};

# Opening a composite must not recount its children: the counter is maintained
# under the lock, so a recount per open made every cold access O(children) and
# wrote to the index on a read path. The 'p:' marker is what calls for a recount.
{
    my $dir = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        $root->mount('u', ['hashmap:ss', 64, ['hashmap:ss', 8], { max_children => 64 }]);
        shared_set($root, "/u/c$_/k", 1) for 1 .. 5;
    }

    my $counted = 0;
    my $orig = \&Data::Shared::Composite::_count_addresses;
    no warnings 'redefine';
    local *Data::Shared::Composite::_count_addresses = sub { $counted++; $orig->(@_) };

    my $root = Data::Shared->open($dir);
    is $counted, 0, 'opening a settled composite does not recount';
    is scalar(() = $root->children('/u')), 5, 'and the counter it kept is right';

    my $index = $root->{mounts}{u}{composite}{index};
    $index->put('s:', 99);
    $index->put('p:', 1);
    undef $root;

    $counted = 0;
    my $after = Data::Shared->open($dir);
    is $counted, 1, 'an unfinished mutation marker does trigger the recount';
    is scalar(() = $after->children('/u')), 5, 'and the bogus counter is repaired';
    is $index->get('p:'), undef, 'the marker is cleared';
}

# Every other call at a missing child allocates it, so the two that retire
# storage would have had to create a child before deleting it -- and would
# have failed on a composite whose budget is already spent.
subtest 'retiring a missing child allocates nothing' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('t', ['hashmap:ss', 100, ['hashmap:si', 64], { max_children => 1 }]);
    shared_set($root, '/t/alice/hits', 1);
    is scalar(() = $root->children('/t')), 1, 'the budget of one is spent';
    for my $verb (qw(unlink destroy)) {
        ok eval { $root->call("/t/bob", $verb); 1 }, "$verb at a missing child is accepted";
        is scalar(() = $root->children('/t')), 1, "and registered no child for $verb";
    }
    ok !eval { shared_set($root, '/t/carol/hits', 1); 1 },
        'while a write at a missing child still wants one';
    like $@, qr/child limit exceeded/, 'and says the budget is spent';
};

done_testing;
