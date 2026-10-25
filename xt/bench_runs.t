use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};

# The PERFORMANCE table is the only published measurement in the dist, and
# nothing executed the scripts it came from. A sibling project shipped a
# benchmark table wrong by four orders of magnitude for a whole release for
# exactly that reason. The tolerance is deliberately wide: this asks whether
# the table still describes the code, not what this host's clock says.
my $root = "$FindBin::Bin/..";

sub run_clean {
    my ($script, %env) = @_;
    my ($errfh, $errfile) = tempfile(UNLINK => 1);
    local @ENV{ keys %env } = values %env;
    my $out = do {
        open my $saved, '>&', \*STDERR or die $!;
        open STDERR, '>&', $errfh or die $!;
        open my $fh, '-|', $^X, "-I$root/lib", $script or die $!;
        my $o = do { local $/; <$fh> };
        close $fh;
        open STDERR, '>&', $saved or die $!;
        $o;
    };
    my $status = $?;
    my $err = do { open my $e, '<', $errfile or die $!; local $/; <$e> };
    return ($status, $out, $err);
}

my @bench = sort glob "$root/bench/*.pl";
cmp_ok scalar @bench, '>=', 5, 'the benchmarks are populated';
for my $script (@bench) {
    my ($name) = $script =~ m{([^/]+)$};
    my ($status, $out, $err) = run_clean($script,
        DS_BENCH_TIME => 0.2, DS_BENCH_CHILDREN => 8, DS_BENCH_KEYS => 200,
        DS_BENCH_REPLAY => 10, DS_BENCH_SIZES => '50', DS_BENCH_WORKING_SET => 16,
        DS_BENCH_ITERATIONS => 50, DS_BENCH_WORKERS => 2);
    is $status, 0, "$name exits 0";
    is $err, '', "$name writes nothing to stderr" or diag $err;
}

# The POD is the source of the expected values, so the two cannot drift apart
# without this test reading the drift.
my %published;
{
    open my $fh, '<', "$root/lib/Data/Shared.pm" or die $!;
    while (my $l = <$fh>) {
        last if %published && $l !~ /us\/op/;
        $published{$1} = $2 if $l =~ /^\s{4}(\S+(?: \S+)?)\s+([\d.]+)\s+us\/op\s*$/;
    }
}
is_deeply [sort keys %published],
    [sort 'array path', 'compiled', 'native handle', 'shared_call', 'string path'],
    'the published table names the five tiers';

my ($status, $out) = run_clean("$root/bench/overhead.pl", DS_BENCH_TIME => 0.3);
my %measured = $out =~ /^(\S+)\s+\S+\/s\s+([\d.]+) us\/op$/mg;
my %label = ('native handle' => 'native', 'compiled' => 'compiled',
             'array path' => 'array', 'shared_call' => 'call', 'string path' => 'string');
for my $tier (sort keys %published) {
    my $got = $measured{ $label{$tier} };
    ok defined $got, "overhead.pl still reports '$label{$tier}' for '$tier'" or next;
    # Both directions: a tier that got four times faster means the table is
    # stale too, and that is worth knowing.
    cmp_ok $got, '<', $published{$tier} * 4, "$tier is within 4x of its published cost";
    cmp_ok $got, '>', $published{$tier} / 4, "$tier is not four times cheaper than published";
}
# The POD's advice to use compiled paths in hot loops rests on this order.
my @order = map { $measured{$_} } qw(native compiled array string);
if (ok !grep({ !defined } @order), 'every tier was measured') {
    cmp_ok $order[0], '<', $order[1], 'a native handle beats a compiled path';
    cmp_ok $order[1], '<', $order[2], 'a compiled path beats an array path';
    cmp_ok $order[2], '<', $order[3], 'an array path beats a string path';
}

done_testing;
