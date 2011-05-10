#!/usr/bin/perl
use warnings;
use strict;
use LWP::Simple 'get';
use JSON::Any;
#use Data::Dump::Streamer 'Dumper';
use Data::Dumper 'Dumper';
use XML::Atom::SimpleFeed;
use Time::ParseDate;
use List::Util 'max';
use Net::Twitter::Lite;
use DateTime::Format::W3CDTF;
use Storable 'retrieve', 'nstore';
use 5.10.0;

# consumer_key
my $twitter_auth = JSON::Any->jsonToObj(do {local (@ARGV, $/) = '/mnt/shared/projects/rss/.twitter'; <>});

my $nt = Net::Twitter::Lite->new(
                                 %$twitter_auth,
                                );

my $user_feed = $nt->user_timeline({screen_name => 'theorbtwo',
                                    trim_user=>0,
                                    include_rts=>1,
                                    include_entities=>1});

my $tweet_cache = {};
my $tweet_cache_file = '/mnt/shared/projects/rss/tweet-cache.storeable';
if (-e $tweet_cache_file) {
  $tweet_cache = retrieve($tweet_cache_file);
}

END {
  nstore($tweet_cache, $tweet_cache_file) or die "Can't store cache to $tweet_cache_file: $!";
}

my $self = bless {}, __PACKAGE__;

my %check;

for my $my_tweet (@$user_feed) {
  $self->add_to_conversation($my_tweet);
  $check{$my_tweet->{id_str}} = $my_tweet;
}

my $mentions_feed = $nt->mentions({trim_user=>0,
                                   include_rts=>1,
                                   include_entities=>1});
for my $mention_tweet (@$mentions_feed) {
  #print Dumper($mention_tweet);

  $self->add_to_conversation($mention_tweet);
  $check{$mention_tweet->{id_str}} = $mention_tweet;
}

# Conversations
my @conv = values %$self;
my %uniq;
@conv = grep {!($uniq{$_}++)} @conv;
@conv = map {+{newest_time => (max map {$_->{time_numeric}} @$_),
               chain => $_}} @conv;
@conv = sort {$b->{newest_time} <=> $a->{newest_time}} @conv;

my $feed = XML::Atom::SimpleFeed->new(
                                      title => "theorbtwo's contextual twitter",
                                      author => 'theorbtwo',
                                      id => 'urn:uuid:5f1c1110-7624-11e0-a1f0-0800200c9a66'
                                     );

my $w3cdtf = DateTime::Format::W3CDTF->new();

for my $conv (@conv) {
  my $title;
  my $html;
  my $time;
  my $id;

  #print "---\n";

  for my $tweet (@{$conv->{chain}}) {
    delete $check{$tweet->{id_str}};

    #print Dumper $tweet;


    # Most importantly: $tweet->{text}, {user}{screen_name}, {time_numeric}
    my $text = html_escape($tweet->{user}{screen_name}).": ".html_escape($tweet->{text});

    #print "$text\n";

    if (!$title) {
      $title = $text;
    }
    
    if (!$id) {
      $id = $tweet->{id};
    }

    if ($html) {
      $html = "$html<br />\n$text";
    } else {
      $html = $text;
    }
    $time = $tweet->{time_numeric};
  }
  #print "---\n";
  
  $feed->add_entry(title => $title,
                   content => $html,
                   # Hm, can I be arsed, at some point, to make these two not the same?  Published should be the earliest time, updated the latest.1
                   updated => $w3cdtf->format_datetime(DateTime->from_epoch(epoch=>$time)),
                   published => $w3cdtf->format_datetime(DateTime->from_epoch(epoch=>$time)),
                   id => "http://desert-island.me.uk/~theorb/twitter-long-feed/$id",
                  );
}
print "Content-type: application/atom+xml\n\n";

$feed->print;

if (%check) {
  warn "Tweets not in the generated Atom?";
  warn Dumper(\%check);
}

sub html_escape {
  my $_=shift;
  s/&/&amp;/g;
  s/</&lt;/g;
  return $_;
}

sub add_to_conversation {
  my ($self, $tweet) = @_;

  if (not ref $tweet) {
    $tweet = fetch_tweet($tweet);
  }

  $tweet->{time_numeric} = parsedate($tweet->{created_at});

  #print "$tweet->{id_str}: Attempting to add tweet $tweet->{id_str} to a conversation\n";

  if ($self->{$tweet->{id_str}}) {
    #print "$tweet->{id_str} already added\n";

    return $self->{$tweet->{id_str}};
  }

  if ($tweet->{in_reply_to_status_id_str}) {
    #print "$tweet->{id_str}: has an in-reply-to\n";

    my $ret = add_to_conversation($self, $tweet->{in_reply_to_status_id_str});
    #print "$tweet->{id_str}: returned from add_to_conversation, got $ret\n";

    push @$ret, $tweet;
    $self->{$tweet->{id_str}} = $ret;
    return $ret;
  }
  
  #print "$tweet->{id_str}: is an original\n";

  $self->{$tweet->{id_str}} = [$tweet];

  return $self->{$tweet->{id_str}};
}

sub fetch_tweet {
  my ($id) = @_;

  if (exists $tweet_cache->{$id}) {
    return $tweet_cache->{$id};
  }

  warn "Fetching tweet $id";
  $tweet_cache->{$id} = $nt->show_status({id => $id, trim_user => 0, include_entities => 1});
  # JSON::Any->jsonToObj(get("http://api.twitter.com/1/statuses/show/$id.json?trim_user=0;include_entites=1"));

  return $tweet_cache->{$id};
}
