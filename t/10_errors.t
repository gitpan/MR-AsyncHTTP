use strict;
use warnings;

use Test::More qw/no_plan/;
use Time::HiRes;
use_ok('MR::AsyncHTTP');

my ($t1, $t2);

my $a = MR::AsyncHTTP->new(connect_timeout=>0.5, resolve_timeout=>0.5, response_timeout=>0.1);

#### Wrong/fail test

my $req_id;

### Resolve timeout

*S = *STDERR; close STDERR; #Workaround to not show warning
$t1 = Time::HiRes::time();
$req_id = $a->send_get('http://domain.nonexistent');
$t2 = Time::HiRes::time();
*STDERR = *S;

ok( ($t2-$t1)<0.6, "Resolve timeout check");
ok(!$req_id, "Nonexistent domain");


### Connect timeout

$t1 = Time::HiRes::time();
$req_id = $a->send_get('http://1.1.1.1');
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<0.6, "Connect timeout check");
ok(!$req_id, "Connect timeout");

### Response timeout
$t1 = Time::HiRes::time();
$req_id = $a->send_get('http://search.cpan.org/search?query=nonexistentmodule&mode=all');
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<1.1, "send_get check");
ok( $req_id, "Request id");

$t1 = Time::HiRes::time();
my $res = $a->wait($req_id);
$t2 = Time::HiRes::time();
is( $res, 0, "Response timeout result code");


### Wrong domains test
$t1 = Time::HiRes::time();
$req_id = $a->send_get('http://this.is.wrong.domain/test?123');
$t2 = Time::HiRes::time();
ok( ($t2-$t1)<0.6, "send_get check");

### Wrong domains test
$t1 = Time::HiRes::time();
$req_id = $a->send_get('http://this.is .wrong.domain/test?123');
$t2 = Time::HiRes::time();
