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

# A class without new_anon must still surface its own error, not a fallback one.
my $other = Data::Shared->new;
ok !eval { $other->mount('p', 'perfecthash', undef); 1 },
    'a backend with no anonymous form still errors';

done_testing;
