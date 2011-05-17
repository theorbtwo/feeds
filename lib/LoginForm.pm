package LoginForm;

use strict;
use warnings;

use HTML::FormHandler::Moose;
BEGIN {
  extends 'HTML::FormHandler';
}

has_field 'user' => ( type => 'Text', label => 'Twitter username', required => 1 );
has_field 'submit' => ( type => 'Submit', value => 'Continue');

no HTML::FormHandler::Moose;

1;
