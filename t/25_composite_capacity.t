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
}

done_testing;
