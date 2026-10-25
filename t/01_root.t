use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists shared_call);

my $root = Data::Shared->new;
isa_ok $root, 'Data::Shared';

is shared_get($root, ''), $root, 'empty path returns root';
is shared_get($root, '/'), $root, 'slash returns root';
ok shared_exists($root, ''), 'root exists';
ok !eval { shared_set($root, '', 1); 1 }, 'cannot set root';
like $@, qr/cannot set the root/, 'set root error';

ok !eval { shared_get($root, '/nope/1'); 1 }, 'unknown mount croaks';
like $@, qr/no mount matches/, 'unknown mount error';

subtest 'nested mounts longest prefix' => sub {
    my $r = Data::Shared->new;
    my $h1 = eval { $r->mount('cache', 'hashmap:ii', undef, 1000) };
    if ($@) { plan skip_all => "hashmap unavailable: $@"; return }
    my $h2 = eval { $r->mount('cache/sessions', 'hashmap:ii', undef, 1000) };
    if ($@) { plan skip_all => "hashmap unavailable: $@"; return }
    shared_set($r, '/cache/1', 10);
    shared_set($r, '/cache/sessions/1', 99);
    is shared_get($r, '/cache/1'), 10, 'short mount';
    is shared_get($r, '/cache/sessions/1'), 99, 'longest prefix wins';
    is $r->handle('/cache/sessions'), $h2, 'handle exact mount';
    ok !eval { $r->handle('/cache/sessions/1'); 1 }, 'handle with extra components croaks';
    is_deeply [$r->mounts], ['cache', 'cache/sessions'], 'mounts listed sorted';
    my $info = $r->mount_info('cache');
    is $info->{key}, 'hashmap', 'mount_info key';
    is $info->{class}, 'Data::HashMap::Shared::II', 'mount_info class';
    ok $r->unmount('cache/sessions'), 'unmount';
    # The nested path now falls back to the 'cache' mount, which takes one key
    # component, so it no longer resolves at all.
    ok !eval { shared_get($r, '/cache/sessions/1'); 1 },
        'after unmount, the nested path no longer resolves';
    is_deeply [$r->mounts], ['cache'], 'only the short mount remains';
};

subtest 'duplicate mount croaks' => sub {
    my $r = Data::Shared->new;
    eval { $r->mount('x', 'hashmap:ii', undef, 10) };
    if ($@) { plan skip_all => "hashmap unavailable: $@"; return }
    ok !eval { $r->mount('x', 'hashmap:ii', undef, 10); 1 }, 'duplicate croaks';
    like $@, qr/already exists/, 'duplicate error';
};

subtest 'unknown spec croaks' => sub {
    my $r = Data::Shared->new;
    ok !eval { $r->mount('x', 'nosuchthing', undef); 1 }, 'unknown spec croaks';
    like $@, qr/unknown mount spec/, 'unknown spec error';
    ok !eval { $r->mount('x', 'hashmap:nope', undef); 1 }, 'unknown variant croaks';
};

subtest 'mount by handle and factory are transient' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = Data::Shared->new($dir);
    my $h = eval { $r->mount('cache', 'hashmap:ii', undef, 100) };
    if ($@) { plan skip_all => "hashmap unavailable: $@"; return }
    my $r2 = Data::Shared->new;
    $r2->mount('copy', $h);
    shared_set($r2, '/copy/1', 5);
    is shared_get($r2, '/copy/1'), 5, 'mounted handle works';
    ok $r2->mount_info('copy')->{transient}, 'handle mount is transient';

    my $r3 = Data::Shared->new;
    $r3->mount('made', sub { Data::HashMap::Shared::II->new(undef, 100) });
    shared_set($r3, '/made/2', 7);
    is shared_get($r3, '/made/2'), 7, 'factory mount works';
};

subtest ':keywords not provided' => sub {
    ok !eval { package KwTest; Data::Shared->import(':keywords'); 1 }, 'keywords croaks';
    like $@, qr/:keywords.*not available/, 'keywords error';
};

done_testing;
