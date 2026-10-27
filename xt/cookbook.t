use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir tempfile);
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};

# Depends on a store the earlier sections built and on a path outside this
# harness, so it cannot run on a root of its own.
my %standalone_exempt = ('FREEZE AND SHIP' => 1);

# The recipes are published code that nothing executed: one of them called
# handle() on a mount it never made, and two did not compile as pasted.
my $base = "$FindBin::Bin/..";
my $pod = "$base/lib/Data/Shared/Cookbook.pod";

open my $fh, '<', $pod or die "$pod: $!";
my (@sections, $current);
my $lineno = 0;
while (my $line = <$fh>) {
    $lineno++;
    if ($line =~ /^=head[12]\s+(.+?)\s*$/) {
        push @sections, $current if $current && @{ $current->{code} };
        # DESCRIPTION is the preamble every other recipe assumes, so it
        # declares the root the harness below supplies.
        $current = $1 eq 'DESCRIPTION' ? undef : { title => $1, line => $lineno, code => [] };
        next;
    }
    push @{ $current->{code} }, $1 if $current && $line =~ /^    (.*)$/;
}
push @sections, $current if $current && @{ $current->{code} };
close $fh;

ok @sections >= 10, 'recipe sections found' or BAIL_OUT('Cookbook layout changed');

my $preamble = <<'PRE';
use strict;
use warnings;
no warnings 'void';
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_delete shared_exists shared_incr
    shared_call shared_push shared_pop shared_compile shared_node shared_children
    shareda_get shareda_set shareda_call sharedc_get sharedc_set sharedc_call);
my $root = Data::Shared->new(tempdir(CLEANUP => 1));
PRE

for my $section (@sections) {
    next if $standalone_exempt{ $section->{title} };
    my $dir = tempdir(CLEANUP => 1);
    open my $out, '>', "$dir/recipe.pl" or die $!;
    print $out $preamble, join("\n", @{ $section->{code} }), "\n";
    close $out or die $!;

    # The croaks that classify a failure go to stderr, so capturing only
    # stdout made every one of them read as a broken recipe.
    my ($errfh, $errfile) = tempfile(UNLINK => 1);
    my $output = do {
        open my $saved, '>&', \*STDERR or die $!;
        open STDERR, '>&', $errfh or die $!;
        open my $run, '-|', $^X, "-I$base/lib", "$dir/recipe.pl" or die $!;
        my $o = do { local $/; <$run> };
        close $run;
        open STDERR, '>&', $saved or die $!;
        $o;
    };
    my $status = $?;
    $output .= do { open my $e, '<', $errfile or die $!; local $/; <$e> };
    next if $status == 0;

    my ($first) = split /\n/, ($output // '');
    $first = '' unless defined $first;
    my $label = "$section->{title} (line $section->{line})";
    if ($first =~ /is not available; install the|Can't locate \S+\.pm/) {
        note "$label: skipped, backend not installed";
        next;
    }
    # A section showing two spellings of one mount names it twice on purpose.
    if ($first =~ /mount '\S+' already exists/) {
        note "$label: alternative forms of one mount";
        next;
    }
    fail "$label runs as pasted";
    diag $first;
}

pass 'every recipe ran, skipped a missing backend, or showed alternatives';
done_testing;
