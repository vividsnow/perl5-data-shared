use strict; use warnings; use Test::More;
use Data::Shared qw(shared_get shared_set shared_exists);
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
done_testing;
