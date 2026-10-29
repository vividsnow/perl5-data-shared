use strict; use warnings; use Test::More;
use Data::Shared qw(shared_get shared_set shared_exists shared_incr shared_call);

# A mount that fails because its dist is absent is a skip; one that fails for
# any other reason is the regression this file exists to catch. `next unless
# eval { mount }` swallowed both the same way, so a broken mount produced no
# tests for that backend and the suite stayed green.
sub mounted {
    my ($root, $name, @spec) = @_;
    return 1 if eval { $root->mount($name, @spec); 1 };
    my $err = $@;
    return 0 if $err =~ /is not available; install the|Can't locate \S+\.pm/;
    fail "mounting '$spec[0]' failed for a reason other than a missing backend";
    diag $err;
    return 0;
}
my $root = Data::Shared->new;
eval { $root->mount('ds', 'disjointset', undef, 100); 1 }
    or plan skip_all => "backend unavailable: $@";
# A bare set() numified the missing member to 0 and unioned with element 0.
# DisjointSet has no split, so that merge could not be undone.
my @w; local $SIG{__WARN__} = sub { push @w, $_[0] };
isnt shared_get($root, '/ds/0'), shared_get($root, '/ds/3'), 'members start apart';
ok !eval { shared_set($root, '/ds/3'); 1 }, 'set without a second member croaks';
like $@, qr/needs a second member/, 'croak explains what is missing';
isnt shared_get($root, '/ds/0'), shared_get($root, '/ds/3'), 'no merge happened';
is scalar @w, 0, 'no uninitialized warning' or diag join '', @w;
shared_set($root, '/ds/8', 9);
is shared_get($root, '/ds/8'), shared_get($root, '/ds/9'), 'the two-member form still unions';

# exists answers 1 or 0 for any path, so a caller probing candidate indices is
# told no rather than dying. Four integer leaves guarded this; two did not.
subtest 'exists is bounded for every integer leaf' => sub {
    my %capacity = (bitset => [1000], pool => [100, 8], buffer => [64],
                    fenwick => [64], segmenttree => [64], disjointset => [64]);
    my $tested = 0;
    for my $key (sort keys %capacity) {
        my $r = Data::Shared->new;
        unless (mounted($r, 'x', $key, undef, @{ $capacity{$key} })) {
            note "$key unavailable, its bounds are not covered here";
            next;
        }
        $tested++;
        my $cap = $capacity{$key}[0];
        for my $idx (0, $cap, $cap + 1_000_000) {
            my $got = eval { shared_exists($r, "/x/$idx") };
            ok !$@, "$key: exists($idx) does not croak" or diag $@;
            ok defined $got && ($got eq '1' || $got eq '0'), "$key: exists($idx) is 1 or 0";
        }
    }
    # As its sibling subtests do: with none of the six installed this would
    # otherwise pass having asserted nothing, under a name that claims all of
    # them. A partial install is ordinary with 39 separate dists.
    plan skip_all => 'no integer leaf available' unless $tested;
};

# graph was the one indexed family left out of that sweep, because it exposes
# no capacity to bound against: has_node numified a negative index into the
# unsigned range and croaked, and croaked again above its own node ceiling.
subtest 'exists is bounded for graph too, which has no capacity to read' => sub {
    my $r = Data::Shared->new;
    mounted($r, 'g', 'graph', undef, 16, 16)
        or plan skip_all => 'graph unavailable';
    for my $idx (-1, 0, 3, 4294967295, 4294967296, 99999999999999) {
        my $got = eval { shared_exists($r, "/g/$idx") };
        ok !$@, "exists($idx) does not croak" or diag $@;
        ok defined $got && ($got eq '1' || $got eq '0'), "exists($idx) is 1 or 0";
    }
    my $id = shared_call($r, '/g', 'add_node', 7);
    is shared_exists($r, "/g/$id"), 1, 'and still answers 1 for a node that is there';
};
# Four indexed leaves guarded their index and three did not, so a non-ASCII
# digit numified to 0 and the write landed on the wrong cell with only a
# warning. Same class as the bitset/pool exists fix, one entry over.
subtest 'every indexed leaf refuses a non-integer index' => sub {
    my $digit = "\x{661}";                      # ARABIC-INDIC DIGIT ONE
    # graph has no set verb, so each case names a verb that entry does map.
    my @cases = (['ndarray', ['f64', 2, 3], 2, 'set'], ['fenwick2d', [24, 7], 2, 'set'],
                 ['graph', [100, 500], 1, 'get'], ['fenwick', [100], 1, 'set'],
                 ['segmenttree', [100], 1, 'set']);
    my $tested = 0;
    for my $case (@cases) {
        my ($key, $args, $dims, $verb) = @$case;
        my $r = Data::Shared->new;
        next unless mounted($r, 'x', $key, undef, @$args);
        $tested++;
        my $call = $verb eq 'set' ? sub { shared_set($r, $_[0], 7) } : sub { shared_get($r, $_[0]) };
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        my $path = '/x/' . join('/', ($digit) x $dims);
        ok !eval { $call->($path); 1 }, "$key: a non-ASCII digit index is refused";
        like $@, qr/index must be an integer/, "$key: by the index guard";
        is scalar @warnings, 0, "$key: and does not warn its way through"
            or diag join '', @warnings;
        # An ordinary index must work, not merely get past the guard: asserting
        # only that the guard did not fire let a backend that had stopped
        # accepting ordinary indices pass just as well.
        my $ok = '/x/' . join('/', (1) x $dims);
        my $went = eval { $call->($ok); 1 };
        my $err = $@;
        if ($key eq 'graph') {
            # graph's get is the one case with nothing to read yet, so here the
            # backend is expected to object -- but about the node, not the index.
            ok !$went, 'graph: reading a node that was never added fails';
            like $err, qr/does not exist/, 'graph: at the backend, not the guard';
        }
        else {
            ok $went, "$key: an ordinary index works" or diag $err;
        }
    }
    plan skip_all => 'no indexed backend available' unless $tested;
};

# The integer class croaks from its XS without a delta, but the Strings
# wrapper interned the member, added nothing, and returned the unchanged score
# as if it had worked -- leaving a ghost member behind for one that was absent.
subtest 'sortedset incr requires a delta' => sub {
    my $tested = 0;
    for my $spec ('sortedset', 'sortedset:strings') {
        my $r = Data::Shared->new;
        my @args = $spec eq 'sortedset' ? (undef, 100) : ({ max => 100 });
        next unless mounted($r, 's', $spec, @args);
        $tested++;
        my $member = $spec eq 'sortedset' ? 1 : 'a';
        shared_set($r, "/s/$member", 10);
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        ok !eval { shared_incr($r, "/s/$member"); 1 }, "$spec: a bare incr is refused";
        is scalar @warnings, 0, "$spec: without warning its way through"
            or diag join '', @warnings;
        is shared_get($r, "/s/$member"), 10, "$spec: and the score is untouched";
        # On an ABSENT member, which is where the ghost came from. Asking after
        # an address the test never touched proved nothing: the refused incr
        # above was aimed at a member that already existed.
        my $ghost = $spec eq 'sortedset' ? 99 : 'ghost';
        ok !eval { shared_incr($r, "/s/$ghost"); 1 },
            "$spec: a bare incr on an absent member is refused too";
        ok !shared_exists($r, "/s/$ghost"), "$spec: a refused incr leaves no member";
        ok eval { shared_incr($r, "/s/$member", 5); 1 }, "$spec: a delta still works" or diag $@;
        is shared_get($r, "/s/$member"), 15, "$spec: and applies it";
    }
    plan skip_all => 'no sortedset backend available' unless $tested;
};

# add() takes a mandatory delta and incr() takes none, so mapping the verb to
# one of them left the other form croaking from the XS.
subtest 'pool incr works with and without a delta' => sub {
    my $tested = 0;
    for my $variant (qw(i64 i32 f64 str)) {
        my $r = Data::Shared->new;
        next unless mounted($r, 'p', "pool:$variant", undef, 100, 8);
        $tested++;
        my $slot = shared_call($r, '/p', 'alloc');
        my $handle = $r->handle('/p');
        # Asserted, not skipped past: a set that stopped working took the incr
        # checks for that variant with it and left the suite green.
        ok eval { shared_set($r, "/p/$slot", 10); 1 }, "pool:$variant: the fixture writes"
            or do { diag $@; next };
        if ($handle->can('incr')) {
            my $bare = eval { shared_incr($r, "/p/$slot"); 1 };
            ok $bare, "pool:$variant: a bare incr works" or diag $@;
            is shared_get($r, "/p/$slot"), 11, "pool:$variant: and adds one";
            ok eval { shared_incr($r, "/p/$slot", 5); 1 }, "pool:$variant: a delta works" or diag $@;
            is shared_get($r, "/p/$slot"), 16, "pool:$variant: and adds the delta";
        }
        else {
            my $bare = eval { shared_incr($r, "/p/$slot"); 1 };
            my $err = $@;
            ok !$bare, "pool:$variant: supports neither form, so it is refused";
            like $err, qr/does not support 'incr'/, "pool:$variant: and says so";
        }
    }
    plan skip_all => 'no pool backend available' unless $tested;
};

subtest 'graph exists answers rather than croaking' => sub {
    my $r = Data::Shared->new;
    plan skip_all => 'graph unavailable' unless eval { $r->mount('g', 'graph', undef, 100, 500); 1 };
    my $id = shared_call($r, '/g', 'add_node', 1);
    is shared_exists($r, "/g/$id"), 1, 'a node that exists';
    is shared_exists($r, '/g/99'), 0, 'and one that does not';
};

subtest 'a one-dimensional leaf refuses a second index' => sub {
    my $r = Data::Shared->new;
    plan skip_all => 'segmenttree unavailable'
        unless eval { $r->mount('arr', 'segmenttree', undef, 100); 1 };
    shared_set($r, '/arr/10', 55);
    is shared_get($r, '/arr/10'), 55, 'the point query works';
    ok !eval { shared_get($r, '/arr/10/20'); 1 }, 'a second index is refused';
    like $@, qr/takes one index/, 'and says so';
};

done_testing;
