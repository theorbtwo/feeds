#!/usr/bin/perl
use warnings;
use strict;
use LWP::Simple 'get';
use JSON::Any;
#use Data::Dump::Streamer 'Dumper';
#use Data::Dumper 'Dumper';
use XML::Atom::SimpleFeed;
use Time::ParseDate;
use List::Util 'max';
use Net::Twitter::Lite;
use DateTime::Format::W3CDTF;
use Storable 'lock_retrieve', 'lock_nstore';
use CGI;
use 5.10.0;

=head1 ADAPTING TO YOUR PURPOSES

=item 1

Change $homedir to a directory which is readable and writable by your web server.

=item 2

Change $user to your twitter username.

=item 3

Go to L<https://dev.twitter.com/apps/new> and register a new
application.  Enter "client" as the application type, and "read-only"
as the default access type.  Leave the callback URL blank.

=item 4

Got to L<https://dev.twitter.com/apps>, click on the name of your new app.

=item 5

Create a file named .twitter in your $homedir, that looks something like this:

  {
    "consumer_key": "abcdefghijklmnopqrstuv",
    "consumer_secret": "abcdefghijklmnopqrstuvwxyzabcdefghijklmno",
    "access_token": "12345678-abcdefghijklmnopqrstuvwxyzabcdefghijklmno",
    "access_token_secret": "abcdefghijklmnopqrstuvwxyzabcdefghijklmno"
  }

=item 6

Copy down your "consumer key" and "consumer secret" from your twitter application page into the correct bits of your new .twitter file.

=item 7

Click on "my access token".

=item 8

Copy down your "access token" and "access token secret" into .twitter.

=cut


my $homedir = "/mnt/shared/projects/rss/";
my $cgi = CGI->new;
my $user = $cgi->param('user');

if (!$user) {
  die "Missing required parameter user=<your user name>";
}

# consumer_key, consumer_secret
my $twitter_auth = JSON::Any->jsonToObj(do {local (@ARGV, $/) = "$homedir/.twitter"; <>});

my $extended_auth = lock_retrieve("$homedir/twitter-user-auth.storeable");
if (not exists $extended_auth->{$user}{auth}) {
  die "$user not logged in, please go to http://FIXME/";
}

$twitter_auth->{access_token} = $extended_auth->{$user}{auth}{access_token};
$twitter_auth->{access_token_secret} = $extended_auth->{$user}{auth}{access_token_secret};

my $nt = Net::Twitter::Lite->new(
                                 %$twitter_auth,
                                );

my $user_feed = $nt->user_timeline({screen_name => $user,
                                    trim_user=>0,
                                    include_rts=>1,
                                    include_entities=>1});

my $tweet_cache = {};
my $tweet_cache_file = "$homedir/tweet-cache.storeable";
if (-e $tweet_cache_file) {
  $tweet_cache = lock_retrieve($tweet_cache_file);
}

END {
  if($tweet_cache) {
    lock_nstore($tweet_cache, $tweet_cache_file) or die "Can't store cache to $tweet_cache_file: $!";
  }
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
                                      title => "$user\'s contextual twitter",
                                      author => "$user",
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

