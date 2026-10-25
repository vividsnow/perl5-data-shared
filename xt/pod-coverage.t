use strict;
use warnings;
use Test::More;
use FindBin;
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};
eval { require Test::Pod::Coverage; Test::Pod::Coverage->import(); 1 }
    or plan skip_all => 'Test::Pod::Coverage required';

pod_coverage_ok('Data::Shared::Registry', 'Registry documented');
pod_coverage_ok('Data::Shared::Compiled', 'Compiled documented');
pod_coverage_ok('Data::Shared',
    { trustme => [qr/^shared/, qr/^(?:get|set|delete|exists|incr|call|push|pop|compile|registry|available_types|dir|readonly|manifest_path|mount_names|node|children)$/] },
    'Shared functions documented by tier in prose');
pod_coverage_ok('Data::Shared::Node',
    { trustme => [qr/^(?:new|get|set|delete|exists|incr|call|push|pop)$/] },
    'Node verbs documented as a group');

# The internal modules used to be listed here one by one with a per-method
# trustme list copied to each. Once the adapters stopped sharing one shape,
# 40 of those names named subs that no longer existed, and a method added
# later would have been exempted from documentation by a pattern nobody had
# reconsidered. Worse, four internal modules were never listed at all.
# Their contract is that they have no documented surface, so assert that.
my @internal = grep { !m{/(?:Node|Compiled|Registry)\.pm$} }
    sort(glob("$FindBin::Bin/../lib/Data/Shared/*.pm"),
         glob("$FindBin::Bin/../lib/Data/Shared/Adapter/*.pm"));
cmp_ok scalar @internal, '>=', 11, 'the internal modules were found';
for my $file (@internal) {
    open my $fh, '<', $file or die "$file: $!";
    my $pod = do { local $/; <$fh> };
    like $pod, qr/^Internal to L<Data::Shared>; not a public API\./m,
        ($file =~ m{(Data/Shared/.+)$})[0] . ' declares itself internal';
}

done_testing;
