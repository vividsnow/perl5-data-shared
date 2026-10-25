use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Scalar::Util qw(weaken);
use Data::Shared;

eval {
    require Data::HashMap::Shared::SS;
    require Data::Sync::Shared::RWLock;
    1;
} or plan skip_all => "composite backends unavailable: $@";

sub mount_maps {
    my ($root, %opts) = @_;
    return $root->mount('users', {
        spec => 'hashmap:ss', args => [256],
        child => { spec => 'hashmap:ss', args => [16] },
        max_children => 128, cache_size => 1, %opts,
    });
}

subtest 'anonymous children survive cache pressure' => sub {
    my $root = Data::Shared->new;
    mount_maps($root);
    $root->set("/users/$_/name", $_) for qw(alice bob charlie);
    is_deeply [map { $root->get("/users/$_/name") } qw(alice bob charlie)],
        [qw(alice bob charlie)], 'all anonymous child values retained';
    $root->delete('/users/alice');
    $root->set('/users/alice/name', 'new');
    is $root->get('/users/alice/name'), 'new', 'deleted anonymous child can be recreated';
};

subtest 'composite runtime does not keep its root alive' => sub {
    for my $compiled (0, 1) {
        my ($weak, $path);
        {
            my $root = Data::Shared->new;
            mount_maps($root);
            $root->set('/users/alice/name', 'alice');
            if ($compiled) {
                $path = Data::Shared::shared_compile('/users/alice/name');
                is Data::Shared::sharedc_get($root, $path), 'alice', 'compiled composite path bound';
            }
            $weak = $root;
            weaken($weak);
        }
        ok !defined $weak, $compiled ? 'compiled composite root released' : 'composite root released';
    }
};

subtest 'registry retains both records for every budgeted child' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    mount_maps($root);
    $root->set("/users/$_/name", "name$_") for 1 .. 128;
    my @children = $root->children('/users');
    is scalar(@children), 128, 'all children registered';
    is_deeply [map { $root->get("/users/$_/name") } 1 .. 128],
        [map { "name$_" } 1 .. 128], 'no construction markers lost before budget';
    # undef numifies to 0, so cmp_ok alone passed if stats ever stopped
    # reporting the counter at all -- the one thing that would hide an
    # unbounded cache.
    my $open = $root->stats->{users}{open};
    ok defined $open, 'the open-child counter is reported';
    cmp_ok $open, '<=', 1, 'file-backed cache stays bounded';
    cmp_ok $open, '>=', 1, 'and the counter is live, not absent';
    ok !eval { $root->set('/users/129/name', 'extra'); 1 }, 'budget enforced';
    like $@, qr/child limit exceeded/, 'budget error';
    my $again = Data::Shared->open($root->dir);
    is_deeply [map { $again->get("/users/$_/name") } 1 .. 128],
        [map { "name$_" } 1 .. 128], 'all values survive replay and cache eviction';
};

subtest 'composite directory aliases fail before sharing storage' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    my $spec = ['hashmap:ss', 100, ['hashmap:ss', 10]];
    $root->mount('a/b', $spec);
    ok !eval { $root->mount('a__b', $spec); 1 }, 'colliding directory rejected';
    like $@, qr/backing path.*already used/, 'collision error';
};

subtest 'string sorted-set sidecars are reserved' => sub {
    eval { require Data::SortedSet::Shared::Strings; 1 }
        or plan skip_all => "string sorted-set backend unavailable: $@";
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    $root->mount('board', 'sortedset:strings', { max => 100 });
    $root->set('/board/alice', 42);
    ok !eval { $root->mount('board__keys', 'hashmap:ss', undef, 100); 1 }, 'sidecar alias rejected';
    like $@, qr/backing path.*already used/, 'sidecar collision error';
    is $root->get('/board/alice'), 42, 'original string sorted-set remains usable';
};

# The child's own unlink left the index naming storage that was gone: this
# process kept writing into the dead mapping and every other one croaked on the
# address, sync_all and freeze_all included.
subtest 'retiring a child through call retires its registration' => sub {
    for my $method (qw(unlink destroy)) {
        my $dir = tempdir(CLEANUP => 1);
        my $root = Data::Shared->new($dir);
        $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
        $root->set('/users/alice/1', 42);
        $root->set('/users/bob/1', 7);
        Data::Shared::shared_call($root, '/users/alice', $method);
        ok !$root->exists('/users/alice'), "$method: the child is no longer registered";
        is_deeply [sort $root->children('/users')], ['bob'], "$method: the sibling stays";
        ok eval { $root->sync_all; 1 }, "$method: sync_all still works" or diag $@;
        undef $root;
        my $reopened = eval { Data::Shared->open($dir) };
        ok $reopened, "$method: another process can still open the store" or diag $@;
        is eval { $reopened->get('/users/bob/1') }, 7, "$method: and read what is left"
            if $reopened;
        # Sealing last: a frozen store is the shipped state and opens read-only.
        ok eval { $reopened->freeze_all; 1 }, "$method: and can still be sealed" or diag $@;
        undef $reopened;
        ok eval { Data::Shared->open_readonly($dir) }, "$method: the sealed store ships" or diag $@;
    }
};

subtest 'retiring a record below a child is refused' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    $root->set('/users/alice/1', 42);
    for my $method (qw(unlink destroy)) {
        ok !eval { Data::Shared::shared_call($root, "/users/alice/1", $method); 1 },
            "$method at a record below a child is refused";
        like $@, qr/retires a composite child, not the record/, "$method: and says why";
    }
    ok $root->exists('/users/alice'), 'the child is still registered';
    is $root->get('/users/alice/1'), 42, 'and its record is intact';
};

subtest 'retiring an address that was never created creates nothing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    $root->mount('users', ['hashmap:ss', 100, ['hashmap:ii', 100]]);
    $root->set('/users/alice/1', 1);
    Data::Shared::shared_call($root, '/users/ghost', 'unlink');
    is_deeply [sort $root->children('/users')], ['alice'], 'no child was created to remove it';
};

done_testing;
