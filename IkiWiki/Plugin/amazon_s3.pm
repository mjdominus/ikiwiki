#!/usr/bin/perl
package IkiWiki::Plugin::amazon_s3;

use warnings;
no warnings 'redefine';
use strict;
use IkiWiki 2.00;
use IkiWiki::Render;
use Net::Amazon::S3;

# Store references to real subs before overriding them.
our %subs;
BEGIN {
	foreach my $sub (qw{IkiWiki::writefile IkiWiki::prune}) {
		$subs{$sub}=\&$sub;
	}
};

sub import { #{{{
	hook(type => "checkconfig", id => "amazon_s3", call => \&checkconfig);
} # }}}

sub checkconfig { #{{{
	foreach my $field (qw{amazon_s3_key_id amazon_s3_key_file
	                      amazon_s3_bucket}) {
		if (! exists $config{$field} || ! defined $config{$field}) {
			error(sprintf(gettext("Must specify %s"), $field));
		}
	}
	if (! exists $config{amazon_s3_prefix} ||
	    ! defined $config{amazon_s3_prefix}) {
	    $config{amazon_s3_prefix}="wiki/";
	}
} #}}}

{
my $bucket;
sub getbucket { #{{{
	return $bucket if defined $bucket;
	
	open(IN, "<", $config{amazon_s3_key_file}) || error($config{amazon_s3_key_file}.": ".$!);
	my $key=<IN>;
	chomp $key;
	close IN;

	my $s3=Net::Amazon::S3->new({
		aws_access_key_id => $config{amazon_s3_key_id},
		aws_secret_access_key => $key,
		retry => 1,
	});

	# make sure the bucket exists
	if (exists $config{amazon_s3_location}) {
		$bucket=$s3->add_bucket({
			bucket => $config{amazon_s3_bucket},
			location_constraint => $config{amazon_s3_location},
		});
	}
	else {
		$bucket=$s3->add_bucket({
			bucket => $config{amazon_s3_bucket},
		});
	}

	if (! $bucket) {
		error(gettext("Failed to create bucket in S3: ").
			$s3->err.": ".$s3->errstr."\n");
	}

	return $bucket;
} #}}}
}

# Given a file, return any S3 keys associated with it.
sub file2keys ($) { #{{{
	my $file=shift;

	my @keys;
	if ($file =~ /^\Q$config{destdir}\/\E(.*)/) {
		push @keys, $config{amazon_s3_prefix}.$1;

		# Munge foo/index.html to foo/
		if ($keys[0]=~/(^|.*\/)index.$config{htmlext}$/) {
			# A duplicate might need to be stored under the
			# unmunged name too.
			if (!$config{usedirs} || $config{amazon_s3_dupindex}) {
				push @keys, $1;
			}
			else {
				@keys=($1);
			}
		}
	}
	return @keys;
} #}}}

package IkiWiki;
use File::MimeInfo;
use Encode;

# This is a wrapper around the real writefile.
sub writefile ($$$;$$) { #{{{
        my $file=shift;
        my $destdir=shift;
        my $content=shift;
        my $binary=shift;
        my $writer=shift;

	# First, write the file to disk.
	my $ret=$IkiWiki::Plugin::amazon_s3::subs{'IkiWiki::writefile'}->($file, $destdir, $content, $binary, $writer);
		
	my @keys=IkiWiki::Plugin::amazon_s3::file2keys("$destdir/$file");

	# Store the data in S3.
	if (@keys) {
		my $bucket=IkiWiki::Plugin::amazon_s3::getbucket();

		# The http layer tries to downgrade utf-8
		# content, but that can fail (see
		# http://rt.cpan.org/Ticket/Display.html?id=35710),
		# so force convert it to bytes.
		$content=encode_utf8($content) if defined $content;

		my %opts=(
			acl_short => 'public-read',
			content_type => mimetype("$destdir/$file"),
		);

		# If there are multiple keys to write, data is sent
		# multiple times.
		# TODO: investigate using the new copy operation.
		#       (It may not be robust enough.)
		foreach my $key (@keys) {
			debug("storing $key");
			my $res;
			if (! $writer) {
				$res=$bucket->add_key($key, $content, \%opts);
			}
			else {
				# This test for empty files is a workaround
				# for this bug:
				# http://rt.cpan.org//Ticket/Display.html?id=35731
				if (-z "$destdir/$file") {
					$res=$bucket->add_key($key, "", \%opts);
				}
				else {
					# read back in the file that the writer emitted
					$res=$bucket->add_key_filename($key, "$destdir/$file", \%opts);
				}
			}
			if (! $res) {
				error(gettext("Failed to save file to S3: ").
					$bucket->err.": ".$bucket->errstr."\n");
			}
		}
	}

	return $ret;
} #}}}

# This is a wrapper around the real prune.
sub prune ($) { #{{{
	my $file=shift;

	my @keys=IkiWiki::Plugin::amazon_s3::file2keys($file);

	# Prune files out of S3 too.
	if (@keys) {
		my $bucket=IkiWiki::Plugin::amazon_s3::getbucket();

		foreach my $key (@keys) {
			debug("deleting $key");
			my $res=$bucket->delete_key($key);
			if (! $res) {
				error(gettext("Failed to delete file from S3: ").
					$bucket->err.": ".$bucket->errstr."\n");
			}
		}
	}

	return $IkiWiki::Plugin::amazon_s3::subs{'IkiWiki::prune'}->($file);
} #}}}

1
