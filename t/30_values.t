use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists shared_delete shared_incr
                    shareda_get shareda_set shared_compile);

sub root_with {
    my ($name, $spec, @args) = @_;
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    return eval { $root->mount($name, $spec, undef, @args); $root };
}

# A verb that consumes a value treated "no value" as a false value, so the
# caller's omission cleared a bit, zeroed a value or zeroed a score -- and
# reported success. @_ < 3, not an undef test: an explicit undef still means
# the caller meant to pass something, as Node::delete reads it.
subtest 'a valueless set is refused, not taken as false' => sub {
    my @cases = (
        ['bitset',    [256],      '/m/10',  1,    'bit'],
        ['radixtree', [1024, 4096], '/m/foo', 7,    'value'],
        ['sortedset', [100],      '/m/42',  1500, 'score'],
    );
    for my $case (@cases) {
        my ($spec, $args, $path, $value, $what) = @$case;
        my $root = root_with('m', $spec, @$args);
        unless ($root) { pass "$spec unavailable"; next }
        shared_set($root, $path, $value);
        ok !eval { shared_set($root, $path); 1 }, "$spec set with no value croaks";
        like $@, qr/needs a (?:value|score)/, "and says a $what is needed";
        is shared_get($root, $path), $value, "the existing $what survives";
        # The backend warns about the undef value itself; that is its call.
        local $SIG{__WARN__} = sub {};
        ok eval { shared_set($root, $path, undef); 1 }, "$spec still accepts an explicit undef";
    }
};

# The exists verbs of these entries refuse a non-integer index. Their siblings
# numified it to 0, so exists called the address absent while get read element
# 0 and set or delete overwrote it.
subtest 'integer-addressed leaves refuse a non-integer index' => sub {
    my $root = root_with('buf', 'buffer:i64', 16);
    plan skip_all => 'buffer backend unavailable' unless $root;
    shared_set($root, '/buf/0', 7);
    my @ops = (
        ['get',    sub { shared_get($root, '/buf/abc') }],
        ['set',    sub { shared_set($root, '/buf/abc', 42) }],
        ['delete', sub { shared_delete($root, '/buf/abc') }],
        ['incr',   sub { shared_incr($root, '/buf/abc') }],
    );
    for my $op (@ops) {
        ok !eval { $op->[1]->(); 1 }, "buffer $op->[0] refuses a non-integer index";
        like $@, qr/index must be an integer/, 'and says so';
    }
    is shared_get($root, '/buf/0'), 7, 'element 0 is untouched';
    # exists is documented to answer 1 or 0 for any path, so it must not croak.
    is shared_exists($root, '/buf/abc'), 0, 'exists still answers 0';
    is shared_exists($root, '/buf/0'), 1, 'and 1 for a real index';
    shared_set($root, '/buf/3', 5);
    is shared_get($root, '/buf/3'), 5, 'a legal index still works';
};

# The string tier refuses an undef or reference path. An array component got
# through unchecked: undef addressed the empty-string key and a reference
# addressed its own stringified address, a different key every run.
subtest 'array path components must be defined strings' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    plan skip_all => 'hashmap backend unavailable'
        unless eval { $root->mount('hs', 'hashmap:ss', undef, 100); 1 };
    $root->mount('c', ['hashmap:ss', 64, ['hashmap:ss', 8]]);
    shareda_set($root, ['hs', 'k'], 'first');
    my $ref = {};
    my @entries = (
        ['shareda_set', sub { shareda_set($root, ['hs', undef], 'x') }],
        ['shareda_get', sub { shareda_get($root, ['hs', undef]) }],
        ['a reference', sub { shareda_set($root, ['hs', $ref], 'x') }],
        ['compile',     sub { shared_compile(['hs', undef]) }],
        ['node',        sub { $root->node(['hs', undef]) }],
        ['children',    sub { $root->children(['c', undef]) }],
        ['handle',      sub { $root->handle(['hs', undef]) }],
    );
    for my $entry (@entries) {
        ok !eval { $entry->[0+1]->(); 1 }, "$entry->[0] refuses it";
    }
    is shareda_get($root, ['hs', '']), undef, 'nothing was written to the empty key';
    is shareda_get($root, ['hs', "$ref"]), undef, 'nor to a stringified address';
    is shareda_get($root, ['hs', 'k']), 'first', 'a legal array path still works';
};

# Already unlinked is the goal state, as it is for freeze_all and a composite
# destroy. A second call reported that the manifest could not be read.
subtest 'unlink_all is idempotent and says what happened' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $root = Data::Shared->new($dir);
    plan skip_all => 'hashmap backend unavailable'
        unless eval { $root->mount('a', 'hashmap:ii', undef, 16); 1 };
    $root->mount('b', 'hashmap:ii', undef, 16);
    shared_set($root, '/a/1', 1);
    cmp_ok $root->unlink_all, '>=', 3, 'first call removes mounts and manifest';
    is $root->unlink_all, 0, 'second call removes nothing';
    is $root->unlink_all, 0, 'and stays idempotent';
    ok !-e "$dir/manifest.json", 'manifest gone';
    ok !-e "$dir/a.shm", 'backing file gone';
    ok !-d "$dir/.children", 'and the composite directory with it';
    ok !eval { $root->mount('z', 'hashmap:ii', undef, 16); 1 }, 'the root is not reusable';
    like $@, qr/this store was unlinked/, 'and the croak says why, not that a file is missing';
};

# \d matches non-ASCII digits, which numify to the element they look like, so
# the first version of this guard was walked straight past. And the shape test
# must be identical in exists and in its siblings, or one accepts what the
# other refuses.
subtest 'the index guard cannot be bypassed and agrees with exists' => sub {
    my $root = root_with('buf', 'buffer:i64', 16);
    plan skip_all => 'buffer backend unavailable' unless $root;
    shared_set($root, '/buf/0', 7);
    local $SIG{__WARN__} = sub {};
    for my $bad ("\x{0661}", "7\n", '+3', 'abc') {
        (my $show = $bad) =~ s/\n/\\n/;
        $show = sprintf 'U+%04X', ord $bad if $bad =~ /\A[^\x00-\x7f]\z/;
        ok !eval { shared_set($root, "/buf/$bad", 999); 1 }, "set refuses $show";
        is shared_exists($root, "/buf/$bad"), 0, "and exists agrees for $show";
    }
    is shared_get($root, '/buf/0'), 7, 'element 0 was never touched';
};

# The string tier accepts the spelling an overloaded object produces, and that
# address is stable, unlike a plain reference's.
subtest 'an object that stringifies is a usable component' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    plan skip_all => 'hashmap backend unavailable'
        unless eval { $root->mount('hs', 'hashmap:ss', undef, 100); 1 };
    my $obj = bless {}, 'Data::Shared::Test::Stringy';
    ok eval { shareda_set($root, ['hs', $obj], 'v'); 1 }, 'accepted as a component';
    is shared_get($root, '/hs/alice'), 'v', 'and addresses what it stringifies to';
    is $root->node(['hs', $obj])->path, '/hs/alice', 'a cursor built from it too';
    ok !eval { shareda_set($root, ['hs', {}], 'v'); 1 }, 'a plain reference is still refused';
    ok !eval { $root->node('/hs')->node(['x', undef]); 1 },
        'a relative array component is validated too';
};

# The leaf's own guard croaks from inside the lifecycle section, which leaves
# the interrupted-mutation marker set and costs the next caller a rebuild.
subtest 'a missing score is refused before the lock is taken' => sub {
    my $root = Data::Shared->new(tempdir(CLEANUP => 1));
    plan skip_all => 'composite backends unavailable'
        unless eval { $root->mount('b', ['sortedset', 1000, ['hashmap:ss', 8]]); 1 };
    shared_set($root, '/b/42/k', 1);
    shared_set($root, '/b/42', 1500);
    my $index = $root->{mounts}{b}{composite}{index};
    ok !eval { shared_set($root, '/b/99'); 1 }, 'a valueless score write croaks';
    is $index->get('p:'), undef, 'and leaves no interrupted-mutation marker';
    is shared_get($root, '/b/42'), 1500, 'the existing score is intact';
    is shared_exists($root, '/b/99'), 0, 'and no child was registered';
};

done_testing;

package Data::Shared::Test::Stringy;
use overload q("") => sub { 'alice' }, fallback => 1;
