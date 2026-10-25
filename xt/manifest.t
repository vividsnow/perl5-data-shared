use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(chdir);
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};
eval { require ExtUtils::Manifest; 1 } or plan skip_all => 'ExtUtils::Manifest required';

chdir "$FindBin::Bin/.." or die $!;
my @missing = ExtUtils::Manifest::manicheck();
my @extra = ExtUtils::Manifest::filecheck();
is_deeply \@missing, [], 'MANIFEST lists existing files' or diag explain \@missing;
is_deeply \@extra, [], 'no files missing from MANIFEST' or diag explain \@extra;
done_testing;
