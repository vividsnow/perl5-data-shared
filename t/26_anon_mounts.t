use strict;
use warnings;
use Test::More;
use Data::Shared qw(shared_get shared_set);

# undef as the path is the documented anonymous form, but every buffer variant
# takes NULL straight into C and rejects it with EFAULT; those classes expose
# new_anon instead, which the facade now falls back to.
# Skip only when the backend is absent: a mount failure must FAIL, not skip,
# or a regression here would be invisible.
plan skip_all => 'Data::Buffer::Shared::I64 not installed'
    unless eval { require Data::Buffer::Shared::I64; 1 };

my $root = Data::Shared->new;
my $mounted = eval { $root->mount('b', 'buffer:i64', undef, 10); 1 };
ok $mounted, 'buffer mounts on an anonymous root' or diag $@;
shared_set($root, '/b/0', 42);
is shared_get($root, '/b/0'), 42, 'and round-trips';

# A class without new_anon must still surface its own error, not a fallback
# one. This used to be asked of perfecthash, whose spec form is validated
# before any constructor runs, so it passed on an unrelated croak and would
# have passed with the fallback deleted. Every installed backend mounts
# anonymously, natively or through new_anon, so the case needs a stand-in.
# The fallback is tried second and the FIRST error is the one that must reach
# the caller, so the stand-in fails both ways and the test names which error it
# got.
{
    package Data::Shared::Test::NoAnon;
    sub new      { die "NoAnon needs a file\n" }
    sub new_anon { die "NoAnon has no anonymous form\n" }
}
$INC{'Data/Shared/Test/NoAnon.pm'} = 1;
my $other = Data::Shared->new;
ok !eval { $other->mount('p', 'Data::Shared::Test::NoAnon', undef, 8); 1 },
    'a backend with no working anonymous form still errors';
like $@, qr/NoAnon needs a file/, "with the constructor's own error, not the fallback's";

done_testing;
