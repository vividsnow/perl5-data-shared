use strict;
use warnings;
use Test::More;
plan skip_all => 'author test' unless $ENV{AUTHOR_TESTING};
eval { require Test::Kwalitee; Test::Kwalitee->import('kwalitee_ok'); 1 }
    or plan skip_all => 'Test::Kwalitee required';
kwalitee_ok('-has_meta_yml');
done_testing;
