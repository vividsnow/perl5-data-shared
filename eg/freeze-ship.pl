#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Data::Shared qw(shared_get shared_set shared_exists);

my $dir = @ARGV ? $ARGV[0] : tempdir(CLEANUP => 1);
print "dir: $dir\n";
{
    my $root = Data::Shared->new($dir);
    $root->mount('seen', 'bloomfilter', undef, 10_000, 0.01) unless grep { $_ eq 'seen' } $root->mounts;
    $root->mount('cache', 'hashmap:ii', undef, 1000) unless grep { $_ eq 'cache' } $root->mounts;
    shared_set($root, '/seen/event-42', 1);
    shared_set($root, '/cache/42', 100);
    $root->freeze_all;
    print "producer: frozen and shipped\n";
}
{
    my $ro = Data::Shared->open_readonly($dir);
    print "consumer readonly=", $ro->readonly,
          " seen/event-42=", shared_exists($ro, '/seen/event-42'),
          " cache/42=", shared_get($ro, '/cache/42'), "\n";
    my $ok = eval { shared_set($ro, '/cache/43', 1); 1 };
    print "consumer write blocked: ", ($ok ? "no" : "yes"), "\n";
}
