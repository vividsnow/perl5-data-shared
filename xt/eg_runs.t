use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};

my $root = "$FindBin::Bin/..";
my @eg = sort glob "$root/eg/*.pl";
ok @eg >= 8, 'examples populated';

for my $eg (@eg) {
    # Warnings go to stderr, so capturing only stdout made the "clean output"
    # assertion below unfalsifiable. Redirect the child's stderr into a file and
    # fold it in. List-form open, so no shell quoting.
    my ($errfh, $errfile) = tempfile(UNLINK => 1);
    my $out = do {
        open my $saved, '>&', \*STDERR or die $!;
        open STDERR, '>&', $errfh or die $!;
        open my $fh, '-|', $^X, "-I$root/lib", $eg or die $!;
        my $o = do { local $/; <$fh> };
        close $fh;
        open STDERR, '>&', $saved or die $!;
        $o;
    };
    my $status = $?;
    $out .= do { open my $e, '<', $errfile or die $!; local $/; <$e> };
    my ($name) = $eg =~ m{([^/]+)$};
    # Four examples mount directly rather than guarding, so without the
    # recommended leaves they exit on the backend-absent croak. That is the
    # right message for a user; it must not read as a broken example here.
    if ($status != 0 && $out =~ /is not available; install the/) {
        note "$name: skipped, backend not installed";
        next;
    }
    is $status, 0, "$name exits 0";
    unlike $out, qr/isn't numeric|Use of uninitialized|Undefined subroutine/, "$name clean output";
}
done_testing;
