use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_call);

my $dir = tempdir(CLEANUP => 1);

my $pid0 = $$;
my $root = Data::Shared->new($dir);
eval { $root->mount('cache', 'hashmap:ii', undef, 1000) };
if ($@) { plan skip_all => "backend unavailable: $@"; }
eval { $root->mount('visitors', 'hyperloglog', undef, 14) };
if ($@) { plan skip_all => "backend unavailable: $@"; }

shared_set($root, '/cache/42', 100);
ok -e "$dir/manifest.json", 'manifest written';
ok -e "$dir/cache.shm", 'backing file auto-named';

my $again = Data::Shared->open($dir);
is_deeply [$again->mounts], ['cache', 'visitors'], 'manifest replay mounts';
is shared_get($again, '/cache/42'), 100, 'reopened reads parent data';

my $pid = fork();
if (!defined $pid) { plan skip_all => 'fork not available'; }
if ($pid == 0) {
    my $child = Data::Shared->open($dir);
    my $ok = (shared_get($child, '/cache/42') == 100);
    shared_set($child, '/cache/43', 200) if $ok;
    exit($ok ? 0 : 1);
}
waitpid $pid, 0;
is $?, 0, 'child opened via manifest only and read';
is shared_get($root, '/cache/43'), 200, 'child write visible to parent';

my $dir2 = tempdir(CLEANUP => 1);
my $r2 = Data::Shared->new($dir2);
$r2->mount('cache', 'hashmap:ii', undef, 100);
my $native = Data::HashMap::Shared::II->new(undef, 100);
$r2->mount('temp', $native);
my $reopened = Data::Shared->open($dir2);
is_deeply [$reopened->mounts], ['cache'], 'transient mount excluded from manifest';
ok !exists { map { $_ => 1 } $reopened->mounts }->{temp}, 'temp not replayed';

done_testing;
