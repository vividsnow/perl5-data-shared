use strict;
use warnings;
use Test::More;
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
pod_coverage_ok('Data::Shared::Composite',
    { also_private => [qr/^(?:parse_node|construct_node)$/],
      trustme => [qr/^(?:new|dispatch_verb|dispatch_pushpop|dispatch_call|children_at|handle_at|delete_subtree|destroy|sync|freeze|frozen|unlink|stats)$/] },
    'Composite internal');
for my $a (qw(Map Set Queue Indexed Sketch Sync)) {
    pod_coverage_ok("Data::Shared::Adapter::$a",
        { trustme => [qr/^(?:perform|perform_push|perform_pop|make_verb|make_bound|make_bound_push|make_bound_pop|make_push|make_pop|_key|_make_pushpop)$/] },
        "Adapter::$a internal");
}
done_testing;
