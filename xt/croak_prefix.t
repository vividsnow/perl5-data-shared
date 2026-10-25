use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find ();
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};

# The POD promises one pattern catches every error this facade raises. The
# promise is only worth the prefix being there, and 61 of the 190 messages
# did not have it, so the rule is checked here rather than remembered.
my @files;
File::Find::find(sub { push @files, $File::Find::name if /\.pm\z/ }, "$FindBin::Bin/../lib");
cmp_ok scalar @files, '>=', 15, 'every module is scanned';

my ($checked, @bare) = (0);
for my $file (sort @files) {
    open my $fh, '<', $file or die "$file: $!";
    my ($rel, $n) = ($file =~ m{(lib/.*)}s ? $1 : $file, 0);
    while (my $line = <$fh>) {
        $n++;
        next unless $line =~ /Carp::croak\(/;
        # A croak of a variable or of a message built elsewhere is checked
        # where that message is written; only literals are visible here.
        next unless $line =~ /Carp::croak\(\s*(?:sprintf\s*)?(['"])(.*?)\1/;
        my $msg = $2;
        $checked++;
        push @bare, "$rel:$n: $msg" unless $msg =~ /\AData::Shared: /;
    }
    close $fh;
}
cmp_ok $checked, '>=', 120, 'and a realistic number of literal messages seen';
is_deeply \@bare, [], 'every literal croak message carries the facade prefix'
    or diag join "\n", @bare;

done_testing;
