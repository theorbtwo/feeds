#!/usr/bin/perl
use warnings;
use strict;
use LWP::Simple 'mirror';
use lib '/mnt/shared/projects/rss/lib';
use XML::Feed;
use Data::Dump::Streamer;
use LWP::Simple;
use List::Util 'shuffle';
use 5.10.0;
$|=1;

my @entries;

mkdir '/tmp/rss-merge-cache/';

my $start_time = time;

for my $url (shuffle(
                     # This one was being questionable under pipes: should return photos by me, seems to return random shit?
                     'http://api.flickr.com/services/feeds/photos_public.gne?id=43154817@N00&lang=en-us&format=atom',
                     # Flickr photos *of* me.
                     'http://www.flickr.com/services/feeds/profile_photos.gne?nsid=43154817@N00&lang=en-us&format=atom',
                     'http://www.goodreads.com/user/updates_rss/4483087?key=ba7490ed116a03b6b2a9f2224de2c705460266cd',
                     # Uses two-digit years!
                     'https://feeds.foursquare.com/history/0AJSBCRFMO5HIURYX314JO1Y14XJPK4K.rss',
                     'http://desert-island.me.uk/~theorb/twitter-long-feed.pl',
                     'http://github.com/theorbtwo.atom',
                     'http://www.thingiverse.com/rss/user:125',
                    )
                    ) {
  my $file = "".$url;
  $file =~ s!/!-!g;
  $file = "/tmp/rss-merge-cache/$file";

  if (time - $start_time < 5) {
    my $ret = mirror($url, $file);
    if (!($ret ~~ [200, 304])) {
      die "Got $ret fetching $url";
    }
  } else {
    warn "Using old vesion of $url";
  }

  my $in_feed = XML::Feed->parse($file) or die XML::Feed->errstr();

  if (not $in_feed->entries) {
    warn "Empty feed from URL $url";
  }

  for my $entry ($in_feed->entries) {
    #Dump $entry;

    if (!URI->new($entry->id)) {
      # http://feedvalidator.org/docs/error/InvalidFullLink.html -- id must be a valid URI.
      $entry->id($url . $entry->id);
    }

    if (!$entry->author) {
      $entry->author('theorbtwo');
    }

    push @entries, $entry;
  }
}


@entries = sort {
  if (not $a->modified and not $a->issued) {
    Dump $a;

    my $temp_feed = XML::Feed->new('Atom');
    $temp_feed->add_entry($a);
    print $temp_feed->as_xml;

    die "Confusing entry $a: ".$a->title;
  }

  ($a->modified || $a->issued || DateTime->now) <=> ($b->modified || $b->issued || DateTime->now)
} @entries;

my $out_feed = XML::Feed->new('Atom');
$out_feed->title("theorbtwo's unified feed");
$out_feed->id('http://desert-island.me.uk/~theorb/merged.pl');
# Should I make this return the most recent updated time of any entry instead?
$out_feed->updated(DateTime::Format::W3CDTF->format_datetime(DateTime->now));
$out_feed->add_entry($_) for @entries;


print "Content-type: application/atom+xml\n";
print "\n";
print $out_feed->as_xml;
