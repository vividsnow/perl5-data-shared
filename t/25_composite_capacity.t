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

done_testing;
