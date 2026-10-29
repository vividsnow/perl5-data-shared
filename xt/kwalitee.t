use strict;
use warnings;
use Test::More;
use FindBin;
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};
eval { require Test::Kwalitee; Test::Kwalitee->import('kwalitee_ok'); 1 }
    or plan skip_all => 'Test::Kwalitee required';

# The metadata indicators are most of the reason to run this, and they pass
# vacuously wherever META.yml and META.json are absent -- which is every
# checkout, since only `make distdir` writes them. So this is a check on the
# release directory, and from a checkout it says so rather than passing
# silently. Skipped, not bailed: `prove -r xt/` has to keep working here.
chdir "$FindBin::Bin/.." or die $!;
plan skip_all => 'not a release directory: run this inside the make distdir output'
    if -d '.git';
# Past that point this IS a release directory, so a missing META is a failure
# and not another reason to skip -- which is the hole this test started with.
ok -f $_, "$_ ships" for qw(META.yml META.json);

# Test::Kwalitee skips CPANTS' separate-license indicator as experimental.
ok -f 'LICENSE', 'separate LICENSE file is shipped';
kwalitee_ok();
done_testing;
