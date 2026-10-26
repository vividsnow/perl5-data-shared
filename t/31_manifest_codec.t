use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use Data::Shared qw(shared_get shared_set);
use Data::Shared::Manifest ();

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

# A float is written with %.15g, so a whole number that arrived as a float --
# 2**50 is one, the same digits typed out are not -- was replayed several short
# of the value the store was built with.
# Whether a scalar is written as a number depends on flag history the caller
# cannot see: a string used once in numeric context carries numeric flags and
# is still quoted, so a flag test refused a legitimate string argument.
subtest 'only a real Inf or NaN is refused, not a string that looks like one' => sub {
    my $looks_numeric = 'inf';
    my $forced = $looks_numeric + 0;
    my ($kept) = Data::Shared::Manifest::snapshot($looks_numeric);
    is $kept, 'inf', 'a string used numerically is kept as a string';
    for my $label ('nan', 'NaN.shm', 'Infinity.shm', '-inf') {
        my ($keep) = Data::Shared::Manifest::snapshot($label);
        is $keep, $label, "the string '$label' is kept";
    }
    my $real_inf = 'Inf' + 0;
    my $stringified = "$real_inf";
    ok !eval { Data::Shared::Manifest::snapshot($real_inf); 1 },
        'a real Inf is refused even after being stringified';
    ok !eval { Data::Shared::Manifest::snapshot('NaN' + 0); 1 }, 'and a real NaN';
};

subtest 'a numeric mount argument survives the round trip exactly' => sub {
    # The bounds matter most: int() hands back the same float at IV_MIN and
    # above IV_MAX, so a conversion written with it did nothing for exactly
    # the values it was written for.
    for my $value (2**50, 2**53, 2**62, -(2**63), 2**63, 1e15,
                   1125899906842624, 3600000000, 0.1, 1.5, -2**50, 1e300) {
        my ($stored) = Data::Shared::Manifest::snapshot($value);
        my $json = JSON::PP->new->canonical(1)->ascii(1)->encode([$stored]);
        my $back = JSON::PP->new->decode($json)->[0];
        cmp_ok $back, '==', $value, "$value round trips exactly";
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
