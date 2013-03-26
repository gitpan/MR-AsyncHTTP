package MR::AsyncHTTP;

use strict;
use warnings;
use Carp;
use Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Time::HiRes();

our $VERSION = '0.01';

=head1 NAME

MR::AsyncHTTP - A zero-overhead Perl module for requesting HTTP in async manner, without event pools

=head1 SYNOPSIS

  use MR::AsyncHTTP;
  my $asynchttp = new MR::AsyncHTTP( connect_timeout=>0.6 );

  # Send a request, dont wait answer right now
  my $req_id = $asynchttp->send_get( "http://example.com/" );

  #..work with something else..
  my $res = $asynchttp->check_response($req_id);
  if( !$res ) {
    # Not ready yet, work on something other
  }
  
  #..Finally, wait it.
  my $res = $asynchttp->wait($req_id);

  #..Send a couple of requests
  for(1..5) {
    $asynchttp->send_get( "http://example.com/request/".$_ );
  }

  #Dedicate some time for sysread() to free buffers
  $asynchttp->poke;

  # Wait all responses
  $asynchttp->wait_all;

=head1 DESCRIPTION

 Note this module have limited functionality compared to say, LWP. Its designed to make simple requests async, thats all.

=head2 new(%opts)

Captain: create a new object.

%opts can be:

=over 4

=item resolve_timeout

Timeout for gethostbyname(). Default is 0.5 second. 0 to point no timeout.

=item resolve_cache

Enable caching result of gethostbyname(). A B<false> means no resolve cache. 'local' means object-scope cache.
Other true values mean global cache between instances.

Default is 1 (global).

=item connect_timeout

Set timeout for socket connect(). Default is 0.2 second. 0 to point no timeout.

=item response_timeout

Set timeout for response, not including connect. Affect wait() and wait_all() so they wont block like forever. Default is 1 second.

=back

=cut

sub new {
	my ($class, %opt) = @_;
	$opt{resolve_timeout} = defined($opt{resolve_timeout}) ? ($opt{resolve_timeout}+0) : 0.5;
	$opt{connect_timeout} = defined($opt{connect_timeout}) ? ($opt{connect_timeout}+0) : 0.2;
	$opt{resolve_cache} = defined($opt{resolve_cache}) ? $opt{resolve_cache} : 1;
	$opt{response_timeout} = defined($opt{response_timeout}) ? $opt{response_timeout} : 1;
	return bless {
		opt => \%opt,
		req_id => 1,
	} => $class;
}

=head2 send_get(url, headers)

Send HTTP GET on given url. headers is a hash field=>value

Returns ID of request. Or undef on fail (sets $@ variable); 0 on timeout

=cut

sub send_get {
	my ($self, $url, $headers) = @_;
	$headers = ref($headers) eq 'HASH' ? $headers : {};
	my $was_timeout=0;
	my $ret = eval {
		local $SIG{ALRM} = sub {
			$was_timeout=1;
			die "alarm\n";
		};

		# Resolve addr.
		Time::HiRes::ualarm($self->{opt}->{resolve_timeout} * 1_000_000) if $self->{opt}->{resolve_timeout}; #Convert into ms
		my $r = $self->_parse_url($url);
		unless( $r && $r->{hostname} && $r->{proto} eq 'http' ) {
			Time::HiRes::ualarm(0) if $self->{opt}->{resolve_timeout};
			$@ = "Cant parse url '$url'";
			return undef;
		}
		$r->{ipaddr} = $self->_resolve_addr($r->{hostname});
		unless( $r->{ipaddr} ) {
			Time::HiRes::ualarm(0) if $self->{opt}->{resolve_timeout};
			carp "Cant resolve hostname '$r->{hostname}'; url='$url'";
			$@ = "Cant resolve hostname '$r->{hostname}'";
			return undef;
		}
		Time::HiRes::ualarm(0) if $self->{opt}->{resolve_timeout};

		# Create socket, connect
		Time::HiRes::ualarm($self->{opt}->{connect_timeout} * 1_000_000) if $self->{opt}->{connect_timeout}; #Convert into ms
		my $sock;
		unless( socket($sock, PF_INET, SOCK_STREAM, getprotobyname('tcp')) ) {
			Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
			$@ = "Cant create socket: $!";
			return undef;
		}
		my $port = getservbyname($r->{proto}, 'tcp');
		unless( $port ) {
			close $sock;
			Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
			$@ = "Cant getservbyname";
			return undef;
		}
		unless( connect($sock, pack_sockaddr_in($port, $r->{ipaddr})) ) {
			close $sock;
			Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
			$@ = "Cant connect: $!";
			return undef;
		}

		# Drop a request to socket
		$headers->{Host} = $r->{hostname};
		$headers->{Connection} = 'close';
		$headers->{'User-Agent'} ||= "perl/MR::AsyncHTTP $VERSION";
		my $wr = 1;
		$wr = $wr && syswrite $sock, "GET $r->{uri} HTTP/1.1\n";
		while( my ($key, $value) = each %{$headers} ) {
			$wr = $wr && syswrite $sock, "$key: $value\n";
		}
		$wr = $wr && syswrite $sock, "\n";

		unless( $wr ) {
			close $sock;
			Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
			$@ = "Cant write socket: $!";
			return undef;
		}

		unless( $self->_set_nonblocking($sock, 1) ) {
			close $sock;
			Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
			$@ = "_set_nonblocking fail: $!";
			return undef;
		}

		my $req = {
			id => $self->{req_id}++,
			sock => $sock,
			req_sent => Time::HiRes::time(),
			r => $r,
			url => $url
		};
		$self->{req}->{ $req->{id} } = $req;
		Time::HiRes::ualarm(0) if $self->{opt}->{connect_timeout};
		return $req->{id};
	};#eval
	if( $was_timeout ) {
		$@ = "Resolve/Connection timeout";
		return 0;
	}
	return $ret;
}

=head2 check_response(req_id)

Nonblocking check for response. Returns respnse hash when response is complete.

=cut

sub check_response {
	my ($self, $req_id) = @_;
	my $req = $self->{req}->{$req_id};
	unless( $req ) {
		carp "No such request id '$req_id'. This is cleanly a bug.";
		$@ = "No such requst id";
		return undef;
	}
	return $req->{result} if $req->{done};

	$req->{result}->{body}='' unless defined $req->{result}->{body};
	my $buf;
	my $rd;
	# Socket is in nonblocking mode unless we called from wait()
	while( $rd=sysread($req->{sock}, $buf, 4096) ) {
		$req->{result}->{body} .= $buf;
	}
	if( defined($rd) and $rd==0 ) {
		# Got EOF, split headers
		my $rawheaders;
		$req->{result}->{body} =~ s/^(.*?\r?\n)\r?\n/ $rawheaders=$1; '' /se;
		$req->{result}->{code} = $1 if $rawheaders =~ /^HTTP\/1\.1 (\d+)/;
		foreach my $line ( split(/\r\n/, $rawheaders) ) {
			if( $line =~ /^([^:]+): ([^\r\n]+)/ ) {
				$req->{result}->{headers}->{$1} = $2;
			}
		}
		$req->{done}=1;
		$req->{wait_time} = Time::HiRes::time() - $req->{req_sent};
		#Free socket.
		close($req->{sock}) if $req->{sock};
		$req->{sock}=undef;
		return $req;
	}
	return undef;
}

=head2 wait(req_id)

Wait for response upto response_timeout. Returns response hash or 0 if timeout.

=cut

sub wait {
	my ($self, $req_id) = @_;
	my $req = $self->{req}->{$req_id};
	unless( $req ) {
		carp "No such request id '$req_id'. This is cleanly a bug.";
		$@ = "No such requst id";
		return undef;
	}
	return $req->{result} if $req->{done};

	my $was_timeout;
	my $ret = eval {
		local $SIG{ALRM} = sub {
			$was_timeout=1;
			die "alarm\n";
		};

		Time::HiRes::ualarm($self->{opt}->{response_timeout} * 1_000_000) if $self->{opt}->{response_timeout}; #Convert into ms
		$self->_set_nonblocking($req->{sock}, 0); #Setup blocking mode
		my $res = $self->check_response($req_id);
		Time::HiRes::ualarm(0);
		return $res;
	};
	if( $was_timeout ) {
		$self->_set_nonblocking($req->{sock}, 1); #Setup nonblocking mode
		$@ = "Timeout for response";
		return 0;
	}
	return $ret;
}

=head2 poke()

Dedicate some time for sysread() to free system buffers.

Returns number of requests ready for processing in scalar context or list of ready ids in list context.

=cut

sub poke {
	my $self = shift;
	my @rdy;
	while( my ($req_id, $req) = each(%{$self->{req}}) ) {
		if( $req->{done} ) {
			push @rdy, $req->{id};
			next;
		}
		my $res = $self->check_response($req_id);
		push( @rdy, $res->{id} ) if( $res && $res->{id} && $res->{done} );
	}
	return wantarray ? @rdy : scalar(@rdy);
}

=head2 wait_all()

Blocking wait for all responses. Returns undef.

=cut

sub wait_all {
	my $self = shift;
	foreach my $req_id (keys %{$self->{req}}) {
		$self->poke; #Before blocking on one request, make sure all other's buffers are able to continue receive
		$self->wait($req_id);
	}
	return undef;
}

sub DESTROY {
	my $self = shift;
	foreach my $req (values %{$self->{req}}) {
		close($req->{sock}) if $req->{sock};
		$req->{sock}=undef;
	}
}

#### Private methods ####
sub _parse_url {
	my ($self, $url) = @_;
	if( $url && $url =~ /^([hH][tT][tT][pP]):\/\/([^\/]+)(.*)$/ ) {
		return {
			proto => lc($1),
			hostname => $2,
			uri => ($3 eq '' ? '/' : $3)
		};
	}
	return undef;
}

my $global_resolve_cache = {};
sub _resolve_addr {
	my ($self, $hostname) = @_;
	return inet_aton($hostname) if $hostname =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;
	return $self->{resolve_cache}->{$hostname} if exists($self->{resolve_cache}->{$hostname}); #A local cache
	return $global_resolve_cache->{$hostname}
		if( $self->{opt}->{resolve_cache} and $self->{opt}->{resolve_cache} ne 'local' and exists($global_resolve_cache->{$hostname}) );

	my $ip = gethostbyname($hostname);

	if( $self->{opt}->{resolve_cache} ) { #Cache result
		if( $self->{opt}->{resolve_cache} eq 'local' ) {
			$self->{resolve_cache}->{$hostname} = $ip;
		}else{
			$global_resolve_cache->{$hostname} = $ip;
		}
	}
	return $ip;
}

sub _set_nonblocking {
	my ($self, $sock, $nonblocking_on) = @_;
	$nonblocking_on ||= 0;
	my $flags = fcntl($sock, F_GETFL, 0) or return undef;
	$flags &= (~O_NONBLOCK);
	fcntl($sock, F_SETFL, $flags | ($nonblocking_on && O_NONBLOCK) ) or return undef;
	return 1;
}

1;
__END__

=head1 BUGS / CAVEATS

Limited functionality. Does not support nonstandard ports yet. Does not suport SSL yet.

Module massively rely on Time::HiRes::ualarm. So it uses ALRM signal. So do not wrap it with alarm() or ualarm().

=head1 AUTHOR

Alt, E<lt>alt@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Alt

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.2 or,
at your option, any later version of Perl 5 you may have available.


=cut
