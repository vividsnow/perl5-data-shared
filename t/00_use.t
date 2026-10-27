use strict;
use warnings;
use Test::More;

BEGIN { use_ok('Data::Shared') or BAIL_OUT('cannot load Data::Shared') }
BEGIN { use_ok('Data::Shared::Registry') or BAIL_OUT('cannot load Registry') }
BEGIN { use_ok('Data::Shared::Compiled') or BAIL_OUT('cannot load Compiled') }

is $Data::Shared::VERSION, '0.01', 'version';

my @types = Data::Shared->available_types;
is scalar(@types), 39, 'registry covers 39 dists';
for my $k (qw(hashmap bloomfilter buffer queue ndarray hyperloglog sync perfecthash topk fenwick)) {
    ok((grep { $_ eq $k } @types), "registry has $k");
}

my $r = Data::Shared::Registry::resolve_spec('hashmap:ii');
is $r->{class}, 'Data::HashMap::Shared::II', 'resolve hashmap:ii';
is $r->{variant}, 'ii', 'variant is lowercase';
is $r->{entry}{key}, 'hashmap', 'entry key';

my $r2 = Data::Shared::Registry::resolve_spec('buffer:i64');
is $r2->{class}, 'Data::Buffer::Shared::I64', 'resolve buffer:i64';
is $r2->{variant}, 'i64', 'buffer variant is lowercase';

my $r3 = Data::Shared::Registry::resolve_spec('Data::HashMap::Shared::SS');
is $r3->{class}, 'Data::HashMap::Shared::SS', 'resolve full class';
is $r3->{variant}, 'ss', 'full class variant is lowercase';
is $r3->{entry}{key}, 'hashmap', 'full class maps to entry';

is Data::Shared::Registry::resolve_spec('hashmap:II')->{variant}, 'ii', 'mixed case resolves to lowercase canonical';

ok(!defined Data::Shared::Registry::resolve_spec('nosuchthing'),
    'unknown short spec is undef');

done_testing;
