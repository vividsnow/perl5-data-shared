use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists shared_call shared_push
    shared_compile sharedc_set sharedc_push shareda_call sharedc_call);

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

# A frozen backend refuses a write too, saying "map is frozen (read-only)",
# which a /read-only/ match cannot tell apart from the facade's own refusal:
# commenting the facade guard out left this file passing. Each tier guards
# itself, so each asserts the facade's exact words.
{
    my $cp = shared_compile('/cache/43');
    for my $tier (['shared_set',   sub { shared_set($ro, '/cache/43', 1) }, 'set'],
                  ['sharedc_set',  sub { sharedc_set($ro, $cp, 1) },        'set'],
                  ['shared_push',  sub { shared_push($ro, '/cache/43', 1) }, 'push'],
                  ['sharedc_push', sub { sharedc_push($ro, $cp, 1) },       'push']) {
        my ($name, $code, $verb) = @$tier;
        ok !eval { $code->(); 1 }, "$name on a read-only root croaks";
        like $@, qr/\AData::Shared: root is read-only, cannot \Q$verb\E\b/,
            "$name is refused by the facade, which names the verb";
    }
}
ok !eval { shared_call($ro, '/seen', 'add', 'mallory'); 1 }, 'readonly native add croaks';
ok !eval { $ro->freeze_all; 1 }, 'freeze on readonly croaks';

ok !eval { Data::Shared->open($dir); 1 }, 'rw reopen of frozen root is refused';

# The Cookbook sends a producer to this croak to learn which mount blocks a
# shipped store. It named only the class, which does not say which mount that
# was -- and a store can hold several mounts of one class.
subtest 'the strict refusal names the mount, not only the class' => sub {
    my $d = tempdir(CLEANUP => 1);
    {
        my $m = Data::Shared->new($d);
        eval { $m->mount('cache', 'hashmap:ii', undef, 64); 1 }
            or plan skip_all => "hashmap unavailable: $@";
        eval { $m->mount('counters', 'buffer:i64', undef, 8); 1 }
            or plan skip_all => "buffer unavailable: $@";
        $m->freeze_all;
    }
    ok !eval { Data::Shared->open_readonly($d, strict => 1); 1 },
        'a store with an unsealable mount is refused';
    like $@, qr/not supported by Data::Buffer::Shared::I64/, 'the class is named';
    like $@, qr/at mount 'counters'/, 'and so is the mount';
};

# The POD promises the three destructive native methods croak on a read-only
# root, and that a raw handle keeps only its file's permissions. Nothing
# asserted either half, and the promise covered a route the root cannot see.
subtest 'the read-only guard covers dispatch, not a raw handle' => sub {
    for my $verb (qw(unlink destroy freeze)) {
        ok !eval { shared_call($ro, '/cache', $verb); 1 }, "native $verb croaks through shared_call";
        # Not /read-only/: the mount guard and the frozen backend both say
        # that, so this file passed with the facade's own guard disabled.
        like $@, qr/\AData::Shared: root is read-only, cannot call '\Q$verb\E'/,
            "and it is the facade that refuses $verb";
    }
    my $raw = $ro->handle('/cache');
    ok $raw, 'a handle is still available on a read-only root';
    ok $raw->can('unlink'), 'and carries its own native unlink';
    is shared_get($ro, '/cache/42'), 100, 'the store is intact after the refusals';
};

# The guard compared the method against bare 'unlink', 'destroy' and 'freeze',
# and perl dispatches a package-qualified string to the same method: the
# qualified spelling unlinked a read-only root's own backing file, and a
# writable root's without retiring the mount. Both left a store that no
# opener can ever replay.
subtest 'a qualified spelling is not a different verb' => sub {
    my $QUALIFIED = 'Data::HashMap::Shared::II::unlink';
    for my $tier (['shared_call',  sub { shared_call($_[0], '/cache', $QUALIFIED) }],
                  ['shareda_call', sub { shareda_call($_[0], ['cache'], $QUALIFIED) }],
                  ['sharedc_call', sub { sharedc_call($_[0], shared_compile('/cache'), $QUALIFIED) }]) {
        my ($name, $code) = @$tier;
        ok !eval { $code->($ro); 1 }, "$name refuses it on a read-only root";
        like $@, qr/\AData::Shared: a call takes a bare method name/, "and says so for $name";
    }
    ok -e "$dir/cache.shm", 'the backing file is still there';
    is shared_get($ro, '/cache/42'), 100, 'and still readable';

    # A writable root reaches the same method, where the bare name would also
    # have retired the mount; the qualified one left the manifest naming a
    # file it had just deleted.
    my $d = tempdir(CLEANUP => 1);
    my $rw = Data::Shared->new($d);
    $rw->mount('cache', 'hashmap:ii', undef, 64);
    $rw->mount('users', ['hashmap:ss', 32, ['hashmap:ii', 16]]);
    ok !eval { shared_call($rw, '/cache', $QUALIFIED); 1 }, 'a writable root refuses it too';
    ok !eval { shared_call($rw, '/users', 'Data::HashMap::Shared::SS::unlink'); 1 },
        'and so does a composite mount, whose parent it would have unlinked';
    ok !eval { shared_call($rw, '/cache', 'Data::HashMap::Shared::II::size'); 1 },
        'the rule is the spelling, not the verb';
    undef $rw;
    ok(Data::Shared->open($d), 'the store still replays');
};

done_testing;
