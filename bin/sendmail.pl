#!/usr/bin/perl
use strict;
use warnings;
use v5.12;

use Data::Dumper qw(Dumper);
use Getopt::Long qw(GetOptions);

use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
use Email::MIME::Creator;

use Cwd qw(abs_path cwd);
use WWW::Mechanize;
use YAML qw();
use Try::Tiny;

binmode( STDOUT, ':encoding(UTF-8)' );
binmode( STDERR, ':encoding(UTF-8)' );

use lib 'lib';
use Perl::Maven::Config;
use Perl::Maven::DB;

my $db = Perl::Maven::DB->new('pm.db');

my $cfg     = YAML::LoadFile('config.yml');
my $mymaven = Perl::Maven::Config->new( $cfg->{mymaven_yml} );
my $config  = $mymaven->config('perlmaven.com');
$mymaven = $config;
my $from = $mymaven->{from};

my %opt;
GetOptions( \%opt, 'to=s@', 'exclude=s@', 'url=s', 'send', ) or usage();
usage() if not $opt{to} or not $opt{url};

my ( $subject, %content ) = build_content();
send_messages();
exit;
################################################################################

sub build_content {
	my $w = WWW::Mechanize->new;
	$w->get( $opt{url} );
	die 'missing title' if not $w->title;
	my $subject = $mymaven->{prefix} . ' ' . $w->title;

	my %content;
	my $utf8 = $w->content;
	$content{html} = $utf8;
	$content{text} = html2text($utf8);

	return $subject, %content;
}

sub send_messages {
	my %todo;

	foreach my $to ( @{ $opt{to} } ) {
		if ( $to =~ /\@/ ) {
			$todo{$to} //= 0;
			say "Including 1 ($to)";
		}
		else {
			my $emails = $db->get_subscribers($to);
			my $total  = scalar @$emails;
			say "Including $total number of addresses ($to)";
			foreach my $email (@$emails) {
				$todo{ $email->[0] } = $email->[1];
			}
		}
	}
	foreach my $no ( @{ $opt{exclude} } ) {
		if ( $no =~ /\@/ ) {
			if ( exists $todo{$no} ) {
				delete $todo{$no};
				say "Excluding 1 ($no)";
			}
		}
		else {
			my $emails = $db->get_subscribers($no);
			my $total  = scalar @$emails;
			say "Excluding $total number of addresses ($no)";
			foreach my $email (@$emails) {
				if ( exists $todo{ $email->[0] } ) {
					delete $todo{ $email->[0] };
				}
			}
		}
	}

	my $planned = scalar keys %todo;
	say "Total number of addresses: $planned";
	my $count = 0;
	foreach my $to ( sort { $todo{$a} <=> $todo{$b} } keys %todo ) {
		$count++;
		say "$count out of $planned to $to";
		next if not $opt{send};
		send_mail($to);
		sleep 1;
	}
	say "Total sent $count. Planned: $planned";
	return;
}

sub send_mail {
	my $to = shift;

	my %type = (
		text => 'text/plain',
		html => 'text/html',
	);

	#print $content{html};
	#exit;

	my @parts;
	foreach my $t (qw(html text)) {
		push @parts, Email::MIME->create(
			attributes => {
				content_type => $type{$t},
				( $t eq 'text' ? ( disposition => 'attachment' ) : () ),
				encoding => 'quoted-printable',
				charset  => 'UTF-8',

				#($t eq 'text'? (filename => "$subject.txt") : ()),
				#($t eq 'text'? (filename => 'plain.txt') : ()),
			},
			body_str => $content{$t},
		);
		$parts[-1]->charset_set('UTF-8');
	}

	#print $parts[0]->as_string;
	#print $parts[1]->body_raw;
	#print $parts[1]->as_string;
	#exit;

	my $msg = Email::MIME->create(
		header_str => [
			'From'    => $from,
			'To'      => $to,
			'Type'    => 'multipart/alternative',
			'Subject' => $subject,
			'List-Id' => $mymaven->{listid},
			'Charset' => 'UTF-8',
		],
		parts => \@parts,
	);
	$msg->charset_set('UTF-8');

	#print $msg->as_string;
	#exit;

	# TODO this is not the best solution to extract the e-mail address
	# but works for now.
	my ($return_path) = $from =~ /<(.*)>/;
	die 'time to fix this regex' if not $return_path;
	try {
		sendmail(
			$msg,
			{
				from      => $return_path,
				transport => Email::Sender::Transport::SMTP->new(
					{
						host => 'localhost',

						#port => $SMTP_PORT,
					}
				)
			}
		);
	}
	catch {
		warn "sending failed: $_";
	};

	return;
}

sub html2text {
	my $html = shift;

	$html =~ s{</?p>}{\n}gi;
	$html =~ s{<a href="([^"]+)">([^<]+)</a>}{$2 [ $1 ]}gi;

	$html =~ s{<[^>]+>}{}g;

	return $html;
}

sub usage {
	print <<"END_USAGE";
Usage: $0 --url http://url
    --send if I really want to send the messages

    --to mail\@address.com
#    --to all                      (all the subscribers) currently not supported

    --exclude       Anything that --to can accept - excluded these

END_USAGE

	my $products = $db->get_products;
	foreach my $code (
		sort
		keys %$products
		)
	{
		say "    --to $code";
	}
	exit;
}
