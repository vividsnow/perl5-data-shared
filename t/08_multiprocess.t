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

# An anonymous root shares a composite index across a fork but has no file to
# reopen, so a child created by the other process lists and exists while every
# deeper access must fail. It used to fail naming the internal node role.
{
    my $anon = Data::Shared->new;
    if (eval { $anon->mount('users', ['hashmap:ss', undef, 100, ['hashmap:ss', undef, 100]]); 1 }) {
        shared_set($anon, '/users/alice/name', 'from-parent');
        my $kid = fork();
        if (defined $kid) {
            if ($kid == 0) { shared_set($anon, '/users/bob/name', 'from-child'); exit 0 }
            waitpid $kid, 0;
            is_deeply [$anon->children('/users')], ['alice', 'bob'], 'forked child is listed';
            ok !eval { shared_get($anon, '/users/bob/name'); 1 }, 'but cannot be reopened';
            like $@, qr{child '/users/bob' exists in the shared index but belongs to another process},
                'the croak names the path, not the internal node role';
            like $@, qr/file-backed root/, 'and says what to do instead';
            is shared_get($anon, '/users/alice/name'), 'from-parent', 'own children unaffected';
        }
    }
}

done_testing;
