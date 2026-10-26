use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set);

my $probe = Data::Shared->new(tempdir(CLEANUP => 1));
eval { $probe->mount('p', 'hashmap:ss', undef, 8); 1 }
    or plan skip_all => "hashmap backend unavailable: $@";

# The manifest carries codepoints, so a path of bytes and its character
# spelling published the same text and the reader could not tell them apart:
# every reopen looked for a different file and refused to recreate it, leaving
# the store intact on disk and unreachable through any API.
subtest 'a non-ASCII backing path survives a round trip' => sub {
    my @forms = (
        ['ASCII',        'store.shm'],
        ['UTF-8 bytes',  "caf\xc3\xa9.shm"],
        ['Latin-1 byte', "caf\xe9.shm"],
        ['flagged char', "caf\x{e9}.shm"],
        ['wide char',    "snow\x{263a}.shm"],
    );
    for my $form (@forms) {
        my ($label, $leaf) = @$form;
        my $dir = tempdir(CLEANUP => 1);
        {
            my $root = Data::Shared->new($dir);
            $root->mount('x', 'hashmap:ss', "$dir/$leaf", 100);
            shared_set($root, '/x/k', 'v');
        }
        my $reopened = eval { Data::Shared->open($dir) };
        ok $reopened, "$label: reopens" or diag $@;
        is eval { shared_get($reopened, '/x/k') }, 'v', "$label: reads the value"
            if $reopened;
    }

    # And the same path through the freeze/ship route, which opens read-only.
    my $dir = tempdir(CLEANUP => 1);
    {
        my $root = Data::Shared->new($dir);
        $root->mount('x', 'hashmap:ss', "$dir/caf\xc3\xa9.shm", 100);
        shared_set($root, '/x/k', 'v');
        $root->freeze_all;
    }
    my $ro = eval { Data::Shared->open_readonly($dir) };
    ok $ro, 'a frozen store with a byte path opens read-only' or diag $@;
    is eval { shared_get($ro, '/x/k') }, 'v', 'and reads back' if $ro;
};

# Each of these publishes text JSON::PP cannot parse again, so the mount
# succeeded and every later topology change and every reopen croaked on a
# manifest only hand-editing could repair. Refused while the caller is still
# there to be told.
subtest 'an unrepresentable mount argument is refused at mount time' => sub {
    my @bad = (
        ['NaN capacity', sub { $_[0]->mount('x', 'hashmap:ss', undef, 'NaN' + 0) },
         qr/not a serializable mount argument/],
        ['Inf capacity', sub { $_[0]->mount('x', 'hashmap:ss', undef, 'Inf' + 0) },
         qr/not a serializable mount argument/],
        ['lone surrogate in a path', sub {
            no warnings 'utf8';
            $_[0]->mount('x', 'hashmap:ss', '/tmp/a' . chr(0xD800) . '.shm', 100) },
         qr/not representable in a manifest/],
    );
    for my $case (@bad) {
        my ($label, $code, $like) = @$case;
        my $dir = tempdir(CLEANUP => 1);
        my $root = Data::Shared->new($dir);
        $root->mount('good', 'hashmap:ss', undef, 100);
        shared_set($root, '/good/k', 'v');
        ok !eval { $code->($root); 1 }, "$label is refused";
        like $@, $like, "$label says why";
        # The refusal happens inside a mount mutation, so it must roll back.
        is_deeply [$root->mounts], ['good'], "$label leaves the mounts alone";
        is shared_get($root, '/good/k'), 'v', "$label leaves the store usable";
        ok eval { $root->mount('later', 'hashmap:ss', undef, 100); 1 },
            "$label does not block a later mount";
        ok eval { Data::Shared->open($dir); 1 }, "$label leaves a parsable manifest";
    }
};

# JSON::PP writes an NV with %.15g and reads 1e+15 back as an integer, so a
# re-encode of the parsed file never matched the writer's own encoding and the
# root was told, permanently, that somebody else had changed the manifest.
subtest 'a float argument does not fake a stale revision' => sub {
    plan skip_all => 'histogram backend unavailable'
        unless eval { require Data::Histogram::Shared; 1 };
    for my $value (1e15, 1000000000000000, 2**50) {
        my $dir = tempdir(CLEANUP => 1);
        my $root = Data::Shared->new($dir);
        $root->mount('h', 'histogram', undef, 1, $value, 3);
        ok eval { $root->mount('m', 'hashmap:ss', undef, 100); 1 },
            "$value: a later mount still works" or diag $@;
        ok eval { Data::Shared->open($dir); 1 }, "$value: the store reopens";
    }
};

# \d matches non-ASCII digits, which numify to a prefix of the value.
subtest 'a non-ASCII digit is not a composite option' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    ok !eval {
        $root->mount('m', ['hashmap:ss', 1000, ['hashmap:ss', 16],
                           { max_children => "1\x{661}" }]);
        1;
    }, 'max_children with a non-ASCII digit is refused';
    like $@, qr/must be an integer/, 'and says what it wanted';
    ok eval { $root->mount('ok', ['hashmap:ss', 1000, ['hashmap:ss', 16],
                                  { max_children => 11 }]); 1 },
        'a plain integer still mounts';
};

done_testing;
