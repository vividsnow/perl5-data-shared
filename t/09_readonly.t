use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists shared_call);

my $dir = tempdir(CLEANUP => 1);
my $root = Data::Shared->new($dir);
eval { $root->mount('seen', 'bloomfilter', undef, 10000, 0.01) };
if ($@) { plan skip_all => "bloomfilter unavailable: $@"; }
eval { $root->mount('cache', 'hashmap:ii', undef, 1000) };
if ($@) { plan skip_all => "hashmap unavailable: $@"; }

shared_set($root, '/seen/alice', 1);
shared_set($root, '/cache/42', 100);
my $frozen = $root->freeze_all;
cmp_ok $frozen, '>=', 1, 'freeze_all froze at least one mount';

my $ro = Data::Shared->open_readonly($dir);
ok $ro->readonly, 'readonly flag';
is shared_exists($ro, '/seen/alice'), 1, 'readonly bloom query';
is shared_get($ro, '/cache/42'), 100, 'readonly hashmap query';

ok !eval { shared_set($ro, '/cache/43', 1); 1 }, 'readonly set croaks at facade';
like $@, qr/read-only/, 'facade readonly error';
ok !eval { shared_call($ro, '/seen', 'add', 'mallory'); 1 }, 'readonly native add croaks';
ok !eval { $ro->freeze_all; 1 }, 'freeze on readonly croaks';

ok !eval { Data::Shared->open($dir); 1 }, 'rw reopen of frozen root is refused';

done_testing;
