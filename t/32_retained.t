use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_call shared_compile sharedc_call);

my $probe = Data::Shared->new(tempdir(CLEANUP => 1));
eval { $probe->mount('p', 'hashmap:ii', undef, 16); 1 }
    or plan skip_all => "hashmap backend unavailable: $@";

sub bytes_under {
    my ($dir) = @_;
    my $total = 0;
    my @queue = ($dir);
    while (my $d = shift @queue) {
        opendir my $h, $d or next;
        for my $e (readdir $h) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            -d $p ? push @queue, $p : ($total += -s $p || 0);
        }
    }
    return $total;
}

# unmount retains storage by design, but nothing removed it afterwards: a
# later mount of the same name adopted it, so a store the caller believed it
# had emptied served the old data, and a program that rotates mounts grew on
# disk without bound.
subtest 'unlink_all removes storage an unmount retained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        $root->mount('cache', 'hashmap:ii', undef, 100);
        $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
        shared_set($root, '/cache/1', 111);
        shared_set($root, '/users/alice/1', 222);
        $root->unmount($_) for $root->mounts;
        cmp_ok bytes_under($dir), '>', 0, 'the storage is still there after unmounting';
        $root->unlink_all;
        is bytes_under($dir), 0, 'and unlink_all removes it';
    }
    my $fresh = Data::Shared->new($dir);
    $fresh->mount('cache', 'hashmap:ii', undef, 100);
    $fresh->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    is shared_get($fresh, '/cache/1'), undef, 'a fresh store does not serve the old value';
    is_deeply [$fresh->children('/users')], [], 'nor the old children';
};

subtest 'unmount can remove the storage with it' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('cache', 'hashmap:ii', undef, 100);
    shared_set($root, '/cache/1', 7);
    ok -e "$dir/cache.shm", 'the backing file exists';
    is $root->unmount('cache', unlink => 1), 1, 'unmount with unlink reports success';
    ok !-e "$dir/cache.shm", 'and the storage is gone';
    ok !eval { $root->unmount('cache', bogus => 1); 1 }, 'an unknown option is refused';
    like $@, qr/unknown unmount option/, 'and named';
};

# The POD says a transient mount is not written to the manifest, but
# republishing it bumped the revision, so every sibling process was told its
# topology was stale -- which breaks forked workers each taking a scratch handle.
subtest 'a transient mount does not publish a revision' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('shared', 'hashmap:ii', undef, 100);
    my $revision = $root->{_revision};
    my $before = do { open my $f, '<', "$dir/manifest.json" or die $!; local $/; <$f> };

    my $handle = Data::HashMap::Shared::II->new(undef, 16);
    $root->mount('scratch', $handle);
    is $root->{_revision}, $revision, 'the revision is unchanged';
    my $after = do { open my $f, '<', "$dir/manifest.json" or die $!; local $/; <$f> };
    is $after, $before, 'and the manifest is byte-identical';

    $root->unmount('scratch');
    is $root->{_revision}, $revision, 'unmounting it does not publish either';
    $root->mount('real', 'hashmap:ii', undef, 16);
    cmp_ok $root->{_revision}, '>', $revision, 'but a real mount still does';
};

# Only the manifest recorded a composite's child chain, and a remount rewrites
# it, so mounting over a retained directory with another child type was
# accepted and the children already there became unreadable.
subtest 'a composite remembers what its storage was created for' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    plan skip_all => 'bloomfilter backend unavailable'
        unless eval { $root->mount('users', ['hashmap:ss', 100, ['bloomfilter', 1000, 0.01]]); 1 };
    shared_set($root, '/users/alice/e1', 1);
    $root->unmount('users');
    ok !eval { $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]); 1 },
        'a different child type is refused';
    like $@, qr/storage was created for/, 'and says what it was created for';
    ok eval { $root->mount('users', ['hashmap:ss', 100, ['bloomfilter', 1000, 0.01]]); 1 },
        'the same chain still mounts' or diag $@;
    is shared_get($root, '/users/alice/e1'), 1, 'with its children intact';
};

# Removing a mount's storage through the native escape hatch left the manifest
# naming it, and then no process could open the store at all.
subtest 'a native unlink retires the mount with the storage' => sub {
    for my $tier (['string', sub { shared_call($_[0], '/cache', 'unlink') }],
                  ['compiled', sub { sharedc_call($_[0], shared_compile('/cache'), 'unlink') }]) {
        my ($label, $call) = @$tier;
        my $dir = tempdir(CLEANUP => 1);
        {
            my $root = Data::Shared->new($dir);
            $root->mount('cache', 'hashmap:ii', undef, 100);
            $root->mount('keep', 'hashmap:ii', undef, 16);
            shared_set($root, '/cache/1', 7);
            shared_set($root, '/keep/1', 9);
            $call->($root);
            ok !(grep { $_ eq 'cache' } $root->mounts), "$label: the mount is gone";
            ok((grep { $_ eq 'keep' } $root->mounts), "$label: the others stay");
        }
        my $reopened = eval { Data::Shared->open($dir) };
        ok $reopened, "$label: the store still opens" or diag $@;
        is eval { shared_get($reopened, '/keep/1') }, 9, "$label: and reads what is left"
            if $reopened;
    }
};

done_testing;
