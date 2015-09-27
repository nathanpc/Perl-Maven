package Perl::Maven::Analyze;
use 5.010;
use Moo;
use MooX::Options;

use Archive::Any ();
use Data::Dumper qw(Dumper);
use MetaCPAN::Client ();
use MongoDB          ();
use LWP::Simple qw(getstore);

#use Sys::Ramdisk ();
use File::Temp qw(tempdir);
use Perl::PrereqScanner;

our $VERSION = '0.11';

option limit => ( is => 'ro', default => 1, format => 'i' );
option verbose => ( is => 'ro', default => 0 );

sub _log {
	my ( $self, $msg ) = @_;
	say $msg if $self->verbose;
}

sub run {
	my ($self) = @_;
	$self->_log('run');

	$self->fetch_cpan;

}

sub fetch_cpan {
	my ($self) = @_;

	my $mcpan  = MetaCPAN::Client->new;
	my $recent = $mcpan->recent( $self->limit );
	my $db     = $self->mongodb('perl');

	while ( my $r = $recent->next ) {    # https://metacpan.org/pod/MetaCPAN::Client::Release
		$self->_log( 'project: ' . $r->distribution . ' version: ' . $r->version );
		my $res = $db->find_one( { project => $r->distribution, version => $r->version } );
		next if $res;                    # already processed

		#my $ramdisk = Sys::Ramdisk->new(
		#	size    => '100m',
		#	dir     => '/tmp/ramdisk',
		#	cleanup => 1,
		#);
		#$ramdisk->mount();
		#my $dir = $ramdisk->dir;
		my $dir = tempdir( CLEANUP => 1 );

		#say $r->distribution;   # EBook-EPUB-Lite
		#say 'Processing ', $r->name;    # EBook-EPUB-Lite-0.71
		my $local_zip_file = $dir . '/' . $r->archive;

		my $rc = getstore( $r->download_url, $local_zip_file );
		if ( $rc != 200 ) {    # RC_OK
			say 'ERROR: Failed to download ', $r->download;
			next;
		}

		#say glob "$dir/*";
		#say -e $local_zip_file ? 'exists' : 'not';

		my $archive = Archive::Any->new($local_zip_file);
		if ( not defined $archive ) {
			say "ERROR: Could not launch Archive::Any for '$local_zip_file'";
			next;
		}
		$archive->extract($dir);
		my @files = $archive->files;

		my $scanner = Perl::PrereqScanner->new;
		my @docs;
		foreach my $file (@files) {

			#say $file;
			my $path = "$dir/$file";
			say "Missing $file" if not -e $path;
			next if $file !~ /\.(pl|pm)$/;

			# Huge files (eg currently Perl::Tidy) will cause PPI to barf
			# So we need to catch those, keep calm, and carry on
			my $prereqs = eval { $scanner->scan_file($path); };
			if ($@) {
				warn $@;
				next;
			}

			my $depsref = $prereqs->as_string_hash();
			my %data    = (
				project => $r->distribution,
				version => $r->version,
				author  => $r->author,

	   # at one point I think I saw cpan module release with the same version number MetaCPAN should probably catch that
	   # but maybe we should also notice, protect ourself and maybe even complain
				file    => $file,
				depends => $depsref,
			);
			push @docs, \%data;

		}

		# not supported in old MongoDB
		#$db->delete_many( { project => $r->distribution } );
		$db->remove( { project => $r->distribution } );

		# not yet supported on the server
		#$db->insert_many( \@docs );
		#$self->mongodb('perl_projects')->insert_one( { project => $r->distribution } );
		foreach my $d (@docs) {
			$db->insert($d);
		}
		$self->mongodb('perl_projects')->insert( { project => $r->distribution } );
	}
	return;
}

1;

# from Perl::Maven::Monitor
sub mongodb {
	my ( $self, $collection ) = @_;
	my $client = MongoDB::MongoClient->new( host => 'localhost', port => 27017 );
	my $database = $client->get_database('PerlMaven');
	return $database->get_collection($collection);
}

1;

