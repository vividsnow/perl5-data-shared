use strict;
use warnings;
use Test::More;
use FindBin;
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};
eval { require Test::Pod; Test::Pod->import(); 1 }
    or plan skip_all => 'Test::Pod required';

# 'lib', not the default: with a blib present Test::Pod checks the build copy,
# so POD edited after the last `make` was not the POD under test. And the
# count, because all_pod_files_ok() reports "no files found" as a SKIP, which
# prove counts as a pass -- run from the wrong directory it was always green.
# Parenthesised, because `sort Test::Pod::all_pod_files('lib')` parses as
# sort SUBNAME LIST and sorts the single string 'lib'.
my @files = sort(Test::Pod::all_pod_files('lib'));
cmp_ok scalar @files, '>=', 14, 'the POD files were found';
pod_file_ok($_) for @files;

# xt/cookbook.t executes every Cookbook recipe, but each module's SYNOPSIS --
# the code a reader actually copies -- was published without ever being
# compiled. Wrapped in a sub, so nothing runs: they address stores that do not
# exist here.
my $synopses = 0;
for my $file (@files) {
    open my $fh, '<', $file or die "$file: $!";
    my $code = '';
    while (my $l = <$fh>) {
        next unless $l =~ /^=head1 SYNOPSIS/ .. $l =~ /^=(?!head1 SYNOPSIS)\w/;
        $code .= $l =~ s/^\s{4}//r if $l =~ /^\s+\S/ || ($code && $l !~ /\S/);
    }
    next unless $code =~ /\S/;
    $synopses++;
    my %seen;
    my @vars = grep { !$seen{$_}++ } $code =~ /([\$\@\%][A-Za-z_]\w*)/g;
    # No warnings: this asks whether the example PARSES, and predeclaring
    # every variable it mentions necessarily shadows the ones it declares.
    ok eval("no warnings;\nsub { my (" . join(', ', @vars) . ");\n$code\n}; 1"),
        "$file SYNOPSIS compiles as pasted" or diag "$@\n$code";
}
# The four public modules. The rest document themselves as internal and
# carry no synopsis on purpose.
cmp_ok $synopses, '>=', 4, 'the synopses were found';

# README is pod2text of the main module, and nothing regenerated or checked
# it: every POD edit this review loop makes ships a README describing the
# text before it.
SKIP: {
    skip 'Pod::Text required', 2 unless eval { require Pod::Text; 1 };
    my $regenerated = '';
    my $parser = Pod::Text->new;
    $parser->output_string(\$regenerated);
    $parser->parse_file("$FindBin::Bin/../lib/Data/Shared.pm");
    open my $fh, '<', "$FindBin::Bin/../README" or die $!;
    my $shipped = do { local $/; <$fh> };
    cmp_ok length $shipped, '>', 1000, 'the shipped README has content';
    is $shipped, $regenerated, 'README is pod2text of the current POD';
}

done_testing;
