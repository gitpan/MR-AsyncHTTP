use strict;
use warnings;

use Test::More qw/no_plan/;
use Time::HiRes;
use_ok('MR::AsyncHTTP');

my ($t1, $t2);

my $a = MR::AsyncHTTP->new(connect_timeout=>0.5, resolve_timeout=>1, response_timeout=>3);

#### Single request test

$t1 = Time::HiRes::time();
my $req_id = $a->send_get('http://www.cpan.org');
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<1.6, "http://www.cpan.org send_get not excess connect_timeout");
ok($req_id, "http://www.cpan.org send_get return request_id");

my $res;
$t1 = Time::HiRes::time();
$res = $a->check_response($req_id);
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<0.3, "http://www.cpan.org check_response is really nonblocking");
ok(!$res, "http://www.cpan.org check_response ok");


$t1 = Time::HiRes::time();
($res) = $a->wait($req_id);
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<3.3, "http://www.cpan.org wait() not excess response_timeout");

ok($res, "http://www.cpan.org wait returned object");
ok($res->{done}, "http://www.cpan.org wait done ok");
is($res->{result}->{code}, 200, "http://www.cpan.org HTTP status");

