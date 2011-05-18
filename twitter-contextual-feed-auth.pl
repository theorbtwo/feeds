#!/usr/bin/perl
use warnings;
use strict;
# no indirect;
use CGI;
use Storable 'lock_nstore', 'lock_retrieve';
#use Net::Twitter::Lite;
use Net::Twitter;
use Template;
use Scalar::Util 'blessed';
use Data::Dump::Streamer 'Dump', 'Dumper';

use lib '/mnt/shared/projects/rss/lib';
use LoginForm;

my $cgi = CGI->new;
my $homedir = "/mnt/shared/projects/rss/";

# consumer_key, consumer_secret
my $twitter_auth = JSON::Any->jsonToObj(do {local (@ARGV, $/) = "$homedir/.twitter"; <>});

my $nt = Net::Twitter->new(
                           %$twitter_auth,
                           traits => [qw<API::REST OAuth>],
                           ssl => 0,
                           # TEMP: Overriding these makes it possible to see error messages via strace / wireshark.
                           oauth_urls => {
                                          request_token_url  => "http://api.twitter.com/oauth/request_token",
                                          authentication_url => "http://api.twitter.com/oauth/authenticate",
                                          authorization_url  => "http://api.twitter.com/oauth/authorize",
                                          access_token_url   => "http://api.twitter.com/oauth/access_token",
                                          xauth_url          => "http://api.twitter.com/oauth/access_token",
                                         },
                          );


#my $extended_auth = lock_retrieve("$homedir/twitter-user-auth.storeable");
#if (not exists $extended_auth->{$user}{auth}) {
#  die "$user not logged in, please go to http://FIXME/";
#}
#$twitter_auth->{access_token} = $extended_auth->{$user}{auth}{access_token};
#$twitter_auth->{access_token_secret} = $extended_auth->{$user}{auth}{access_token_secret};


# MODES!
if (!$cgi->param('user')) {
    show_login_page();
} elsif ($cgi->param('user') and not $cgi->param('oauth_token')) {
  my $user = $cgi->param('user');
  my $forward_url;
  $forward_url = $nt->get_authorization_url(callback => "http://desert-island.me.uk/~theorb/twitter-contextual-feed-auth.pl?user=$user");

  modify_storable($user, {auth=>{request_token => $nt->request_token,
                                 request_token_secret => $nt->request_token_secret}});

  print <<END;
Location: $forward_url

Please go to $forward_url
END
} elsif ($cgi->param('user') and $cgi->param('oauth_token')) {
  # HA, I think we've actually done it!
  my $user = $cgi->param('user');
  my $extended_auth = get_storable($user);

  $nt->request_token($extended_auth->{auth}{request_token});
  $nt->request_token_secret($extended_auth->{auth}{request_token_secret});
  my ($access_token, $access_token_secret, $user_id, $screen_name) = $nt->request_access_token(verifier=>$cgi->param('oauth_verifier'));

  modify_storable($user, {auth=>{access_token => $access_token,
                                 access_token_secret => $access_token_secret},
                          user_id => $user_id,
                          screen_name => $screen_name});


  my $forward_url = "http://desert-island.me.uk/~theorb/twitter-contextual-feed.pl?user=$user";

  print <<END;
Location: $forward_url

Please go to $forward_url
END
} else {
  die "Unknown mode?";
}

sub modify_storable {
  my ($user, $newval) = @_;
  
  my $extended_auth;
  if (!-e "$homedir/twitter-user-auth.storeable") {
    $extended_auth = {};
  } else {
    $extended_auth = lock_retrieve("$homedir/twitter-user-auth.storeable");
  }
  $extended_auth->{$user} = $newval;
  lock_nstore($extended_auth, "$homedir/twitter-user-auth.storeable.new");
  rename("$homedir/twitter-user-auth.storeable.new", "$homedir/twitter-user-auth.storeable");
}

sub get_storable {
  my ($user) = @_;

  my $extended_auth = {};
  if (-e "$homedir/twitter-user-auth.storeable") {
    $extended_auth = lock_retrieve("$homedir/twitter-user-auth.storeable");
  }
  return $extended_auth->{$user};
}

sub show_login_page {
    print "Content-type: text/html\n\n";
    my $tt = Template->new(INCLUDE_PATH => '/mnt/shared/projects/rss');
    my $form = LoginForm->new();
    $form->process(verbose => 1);
    $tt->process('twitter_auth_page.html', { form => $form });
}

