################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2022 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::ContentGenerator::Instructor::ProblemSetDetail;
use parent qw(WeBWorK::ContentGenerator);

=head1 NAME

WeBWorK::ContentGenerator::Instructor::ProblemSetDetail - Edit general set and
specific user/set information as well as problem information

=cut

use strict;
use warnings;

use WeBWorK::Utils qw(cryptPassword jitar_id_to_seq seq_to_jitar_id x format_set_name_internal format_set_name_display);
use WeBWorK::Utils::Instructor qw(assignProblemToAllSetUsers addProblemToSet);

# These constants determine which fields belong to what type of record.
use constant SET_FIELDS => [
	qw(set_header hardcopy_header open_date reduced_scoring_date due_date answer_date visible description
		enable_reduced_scoring  restricted_release restricted_status restrict_ip relax_restrict_ip
		assignment_type use_grade_auth_proctor attempts_per_version version_time_limit time_limit_cap
		versions_per_interval time_interval problem_randorder problems_per_page
		hide_score:hide_score_by_problem hide_work hide_hint restrict_prob_progression email_instructor)
];
use constant PROBLEM_FIELDS =>
	[qw(source_file value max_attempts showMeAnother showHintsAfter prPeriod att_to_open_children counts_parent_grade)];
use constant USER_PROBLEM_FIELDS => [qw(problem_seed status num_correct num_incorrect)];

# These constants determine what order those fields should be displayed in.
use constant HEADER_ORDER => [qw(set_header hardcopy_header)];
use constant PROBLEM_FIELD_ORDER => [
	qw(problem_seed status value max_attempts showMeAnother showHintsAfter prPeriod attempted last_answer num_correct
		num_incorrect)
];
# For gateway sets, don't allow changing max_attempts on a per problem basis.
use constant GATEWAY_PROBLEM_FIELD_ORDER =>
	[qw(problem_seed status value attempted last_answer num_correct num_incorrect)];
use constant JITAR_PROBLEM_FIELD_ORDER => [
	qw(problem_seed status value max_attempts showMeAnother showHintsAfter prPeriod att_to_open_children
		counts_parent_grade attempted last_answer num_correct num_incorrect)
];

# Exclude the gateway set fields from the set field order, because they are only displayed for sets that are gateways.
# This results in a bit of convoluted logic below, but it saves burdening people who are only using homework assignments
# with all of the gateway parameters.
# FIXME: In the long run, we may want to let hide_score and hide_work be set for non-gateway assignments.  Currently
# they are only used for gateways.
use constant SET_FIELD_ORDER => [
	qw(open_date reduced_scoring_date due_date answer_date visible enable_reduced_scoring restricted_release
		restricted_status restrict_ip relax_restrict_ip hide_hint assignment_type)
];
use constant GATEWAY_SET_FIELD_ORDER => [
	qw(version_time_limit time_limit_cap attempts_per_version time_interval versions_per_interval problem_randorder
		problems_per_page hide_score:hide_score_by_problem hide_work)
];
use constant JITAR_SET_FIELD_ORDER => [qw(restrict_prob_progression email_instructor)];

# This constant is a massive hash of information corresponding to each db field.
# This hash should make it possible to NEVER have explicitly: if (somefield) { blah() }
#
# All but name are optional
#   some_field => {
#     name      => "Some Field",
#     type      => "edit",          # edit, choose, hidden, view - defines how the data is displayed
#     size      => "50",            # size of the edit box (if any)
#     override  => "none",          # none, one, any, all - defines for whom this data can/must be overidden
#     module    => "problem_list",  # WeBWorK module
#     default   => 0                # if a field cannot default to undefined/empty what should it default to
#     labels    => {                # special values can be hashed to display labels
#       1 => x('Yes'),
#       0 => x('No'),
#     },
#     convertby => 60,              # divide incoming database field values by this, and multiply when saving

use constant BLANKPROBLEM => 'blankProblem.pg';

# Use the x function to mark strings for localizaton.
use constant FIELD_PROPERTIES => {
	# Set information
	set_header => {
		name     => x('Set Header'),
		type     => 'edit',
		size     => '50',
		override => 'all',
		module   => 'problem_list',
		default  => '',
	},
	hardcopy_header => {
		name     => x('Hardcopy Header'),
		type     => 'edit',
		size     => '50',
		override => 'all',
		module   => 'hardcopy_preselect_set',
		default  => '',
	},
	description => {
		name     => x('Description'),
		type     => 'edit',
		override => 'all',
		default  => '',
	},
	open_date => {
		name     => x('Opens'),
		type     => 'edit',
		size     => '25',
		override => 'any',
	},
	due_date => {
		name     => x('Closes'),
		type     => 'edit',
		size     => '25',
		override => 'any',
	},
	answer_date => {
		name     => x('Answers Available'),
		type     => 'edit',
		size     => '25',
		override => 'any',
	},
	visible => {
		name     => x('Visible to Students'),
		type     => 'choose',
		override => 'all',
		choices  => [qw(0 1)],
		labels   => {
			1 => x('Yes'),
			0 => x('No'),
		},
	},
	enable_reduced_scoring => {
		name     => x('Reduced Scoring Enabled'),
		type     => 'choose',
		override => 'any',
		choices  => [qw(0 1)],
		labels   => {
			1 => x('Yes'),
			0 => x('No'),
		},
	},
	reduced_scoring_date => {
		name     => x('Reduced Scoring Date'),
		type     => 'edit',
		size     => '25',
		override => 'any',
	},
	restricted_release => {
		name      => x('Restrict release by set(s)'),
		type      => 'edit',
		size      => '30',
		override  => 'any',
		help_text => x(
			'This set will be unavailable to students until they have earned a certain score on the sets '
				. 'specified in this field. The sets should be written as a comma separated list. '
				. 'The minimum score required on the sets is specified in the following field.'
		)
	},
	restricted_status => {
		name     => x('Score required for release'),
		type     => 'choose',
		override => 'any',
		choices  => [qw(1 0.9 0.8 0.7 0.6 0.5 0.4 0.3 0.2 0.1)],
		labels   => {
			'0.1' => '10%',
			'0.2' => '20%',
			'0.3' => '30%',
			'0.4' => '40%',
			'0.5' => '50%',
			'0.6' => '60%',
			'0.7' => '70%',
			'0.8' => '80%',
			'0.9' => '90%',
			'1'   => '100%',
		},
	},
	restrict_ip => {
		name     => x('Restrict Access by IP'),
		type     => 'choose',
		override => 'any',
		choices  => [qw(No RestrictTo DenyFrom)],
		labels   => {
			No         => x('No'),
			RestrictTo => x('Restrict To'),
			DenyFrom   => x('Deny From'),
		},
		default => 'No',
	},
	relax_restrict_ip => {
		name     => x('Relax IP restrictions when?'),
		type     => 'choose',
		override => 'any',
		choices  => [qw(No AfterAnswerDate AfterVersionAnswerDate)],
		labels   => {
			No                     => x('Never'),
			AfterAnswerDate        => x('After set answer date'),
			AfterVersionAnswerDate => x('(test) After version answer date'),
		},
		default => 'No',
	},
	assignment_type => {
		name     => x('Assignment type'),
		type     => 'choose',
		override => 'all',
		choices  => [qw(default gateway proctored_gateway jitar)],
		labels   => {
			default           => x('homework'),
			gateway           => x('test'),
			proctored_gateway => x('proctored test'),
			jitar             => x('just-in-time')
		},
	},
	version_time_limit => {
		name      => x('Test Time Limit (min; 0=Close Date)'),
		type      => 'edit',
		size      => '4',
		override  => 'any',
		default   => '0',
		convertby => 60,
	},
	time_limit_cap => {
		name     => x('Cap Test Time at Set Close Date'),
		type     => 'choose',
		override => 'all',
		choices  => [qw(0 1)],
		labels   => {
			'0' => x('No'),
			'1' => x('Yes')
		},
	},
	attempts_per_version => {
		name     => x('Number of Graded Submissions per Test (0=infty)'),
		type     => 'edit',
		size     => '3',
		override => 'any',
		default  => '0',
	},
	time_interval => {
		name      => x('Time Interval for New Test Versions (min; 0=infty)'),
		type      => 'edit',
		size      => '5',
		override  => 'any',
		default   => '0',
		convertby => 60,
	},
	versions_per_interval => {
		name     => x('Number of Tests per Time Interval (0=infty)'),
		type     => 'edit',
		size     => '3',
		override => 'any',
		default  => '0',
		format   => '[0-9]+',                                           # an integer, possibly zero
	},
	problem_randorder => {
		name     => x('Order Problems Randomly'),
		type     => 'choose',
		choices  => [qw(0 1)],
		override => 'any',
		labels   => {
			0 => x('No'),
			1 => x('Yes')
		},
	},
	problems_per_page => {
		name     => x('Number of Problems per Page (0=all)'),
		type     => 'edit',
		size     => '3',
		override => 'any',
		default  => '1',
	},
	'hide_score:hide_score_by_problem' => {
		name     => x('Show Scores on Finished Tests'),
		type     => 'choose',
		choices  => [qw(N:N Y:Y BeforeAnswerDate:N N:Y BeforeAnswerDate:Y)],
		override => 'any',
		labels   => {
			'N:N'                => x('Yes'),
			'Y:Y'                => x('No'),
			'BeforeAnswerDate:N' => x('Only after set answer date'),
			'N:Y'                => x('Totals only (not problem scores)'),
			'BeforeAnswerDate:Y' => x('Totals only, only after answer date')
		},
	},
	hide_work => {
		name     => x('Show Problems on Finished Tests'),
		type     => 'choose',
		choices  => [qw(N Y BeforeAnswerDate)],
		override => 'any',
		labels   => {
			'N'                => x('Yes'),
			'Y'                => x('No'),
			'BeforeAnswerDate' => x('Only after set answer date')
		},
	},
	use_grade_auth_proctor => {
		name     => x('Require Proctor Authorization to'),
		type     => 'choose',
		override => 'any',
		choices  => [qw(Yes No)],
		labels   => {
			Yes => x('Both Start and Grade'),
			No  => x('Only Start')
		},
		default   => 'Yes',
		help_text => x(
			'Proctored tests always require authorization to start the test. "Both Start and Grade" will require '
				. 'login proctor authorization to start and grade proctor authorization to grade. "Only Start" '
				. 'requires grade proctor authorization to start and no authorization to grade.'
		),
	},
	restrict_prob_progression => {
		name     => x('Restrict Problem Progression'),
		type     => 'choose',
		choices  => [qw(0 1)],
		override => 'all',
		default  => '0',
		labels   => {
			'1' => x('Yes'),
			'0' => x('No'),
		},
		help_text => x(
			'If this is enabled then students will be unable to attempt a problem until they have '
				. 'completed all of the previous problems, and their child problems if necessary.'
		),
	},
	email_instructor => {
		name     => x('Email Instructor On Failed Attempt'),
		type     => 'choose',
		choices  => [qw(0 1)],
		override => 'any',
		default  => '0',
		labels   => {
			'1' => x('Yes'),
			'0' => x('No')
		},
		help_text => x(
			'If this is enabled then instructors with the ability to receive feedback emails will be '
				. 'notified whenever a student runs out of attempts on a problem and its children '
				. ' without receiving an adjusted status of 100%.'
		),
	},

	# In addition to the set fields above, there are a number of things
	# that are set but aren"t in this table:
	#    any set proctor information (which is in the user tables), and
	#    any set location restriction information (which is in the
	#    location tables)

	# Problem information
	source_file => {
		name     => x('Source File'),
		type     => 'edit',
		size     => 50,
		override => 'any',
		default  => '',
	},
	value => {
		name     => x('Weight'),
		type     => 'edit',
		size     => 6,
		override => 'any',
		default  => '1',
	},
	max_attempts => {
		name     => x('Max attempts'),
		type     => 'edit',
		size     => 6,
		override => 'any',
		default  => '-1',
		labels   => {
			'-1' => x('unlimited'),
		},
	},
	showMeAnother => {
		name     => x('Show me another'),
		type     => 'edit',
		size     => '6',
		override => 'any',
		default  => '-1',
		labels   => {
			'-1' => x('Never'),
			'-2' => x('Default'),
		},
		help_text => x(
			'When a student has more attempts than is specified here they will be able to view another '
				. 'version of this problem.  If set to -1 the feature is disabled and if set to -2 '
				. 'the course default is used.'
		)
	},
	showHintsAfter => {
		name     => x('Show hints after'),
		type     => 'edit',
		size     => '6',
		override => 'any',
		default  => '-2',
		labels   => {
			'-2' => x('Default'),
			'-1' => x('Never'),
		},
		help_text => x(
			'This specifies the number of attempts before hints are shown to students. '
				. 'The value of -2 uses the default from course configuration. '
				. 'The value of -1 disables hints. '
				. 'Note that this will only have an effect if the problem has a hint.'
		),
	},
	prPeriod => {
		name     => x('Rerandomize after'),
		type     => 'edit',
		size     => '6',
		override => 'any',
		default  => '-1',
		labels   => {
			'-1' => x('Default'),
			'0'  => x('Never'),
		},
		help_text => x(
			'This specifies the rerandomization period: the number of attempts before a new version of '
				. 'the problem is generated by changing the Seed value. The value of -1 uses the '
				. 'default from course configuration. The value of 0 disables rerandomization.'
		),
	},
	problem_seed => {
		name     => x('Seed'),
		type     => 'edit',
		size     => 6,
		override => 'one',
	},
	status => {
		name     => x('Status'),
		type     => 'edit',
		size     => 6,
		override => 'one',
		default  => '0',
	},
	attempted => {
		name     => x('Attempted'),
		type     => 'hidden',
		override => 'none',
		choices  => [qw(0 1)],
		labels   => {
			1 => x('Yes'),
			0 => x('No'),
		},
		default => '0',
	},
	last_answer => {
		name     => x('Last Answer'),
		type     => 'hidden',
		override => 'none',
	},
	num_correct => {
		name     => x('Correct'),
		type     => 'hidden',
		override => 'none',
		default  => '0',
	},
	num_incorrect => {
		name     => x('Incorrect'),
		type     => 'hidden',
		override => 'none',
		default  => '0',
	},
	hide_hint => {
		name     => x('Hide Hints from Students'),
		type     => 'choose',
		override => 'all',
		choices  => [qw(0 1)],
		labels   => {
			1 => x('Yes'),
			0 => x('No'),
		},
	},
	att_to_open_children => {
		name     => x('Att. to Open Children'),
		type     => 'edit',
		size     => 6,
		override => 'any',
		default  => '0',
		labels   => {
			'-1' => x('max'),
		},
		help_text => x(
			'The child problems for this problem will become visible to the student when they either have more '
				. 'incorrect attempts than is specified here, or when they run out of attempts, whichever comes '
				. 'first.  If "max" is specified here then child problems will only be available after a student '
				. 'runs out of attempts.'
		),
	},
	counts_parent_grade => {
		name     => x('Counts for Parent'),
		type     => 'choose',
		choices  => [qw(0 1)],
		override => 'any',
		default  => '0',
		labels   => {
			'1' => x('Yes'),
			'0' => x('No'),
		},
		help_text => x(
			'If this flag is set then this problem will count towards the grade of its parent problem.  In '
				. q{general the adjusted status on a problem is the larger of the problem's status and the weighted }
				. 'average of the status of its child problems which have this flag enabled.'
		),
	},
};

use constant FIELD_PROPERTIES_GWQUIZ => {
	max_attempts => {
		type     => 'hidden',
		override => 'any',
	}
};

# Create a table of fields for the given parameters, one row for each db field.
# If only the setID is included, it creates a table of set information.
# If the problemID is included, it creates a table of problem information.
sub fieldTable {
	my ($self, $userID, $setID, $problemID, $globalRecord, $userRecord, $setType) = @_;

	my $r           = $self->r;
	my $ce          = $r->ce;
	my @editForUser = $r->param('editForUser');
	my $forUsers    = scalar(@editForUser);
	my $forOneUser  = $forUsers == 1;
	my $isGWset     = defined $setType && $setType =~ /gateway/ ? 1 : 0;

	# Needed for gateway/jitar output
	my $extraFields = '';

	# Are we editing a set version?
	my $setVersion = defined($userRecord) && $userRecord->can('version_id') ? 1 : 0;

	# Needed for ip restrictions
	my $ipFields     = '';
	my $numLocations = 0;

	# Needed for set-level proctor
	my $procFields = '';

	my @fieldOrder;
	if (defined $problemID) {
		if ($setType eq 'jitar') {
			@fieldOrder = @{ JITAR_PROBLEM_FIELD_ORDER() };
		} elsif ($setType =~ /gateway/) {
			@fieldOrder = @{ GATEWAY_PROBLEM_FIELD_ORDER() };
		} else {
			@fieldOrder = @{ PROBLEM_FIELD_ORDER() };
		}
	} else {
		@fieldOrder = @{ SET_FIELD_ORDER() };

		($extraFields, $ipFields, $numLocations, $procFields) =
			$self->extraSetFields($userID, $setID, $globalRecord, $userRecord, $forUsers);
	}

	my $rows = $r->c;

	if ($forUsers) {
		push(
			@$rows,
			$r->tag(
				'tr',
				$r->c(
					$r->tag('td', colspan => '3', ''),
					$r->tag('th', $r->maketext('User Value')),
					$r->tag('th', $r->maketext('Class value'))
				)->join('')
			)
		);
	}
	for my $field (@fieldOrder) {
		my %properties;

		if ($isGWset && defined(FIELD_PROPERTIES_GWQUIZ->{$field})) {
			%properties = %{ FIELD_PROPERTIES_GWQUIZ->{$field} };
		} else {
			%properties = %{ FIELD_PROPERTIES()->{$field} };
		}

		# Don't show fields if that option isn't enabled.
		if (!$ce->{options}{enableConditionalRelease}
			&& ($field eq 'restricted_release' || $field eq 'restricted_status'))
		{
			$properties{'type'} = 'hidden';
		}

		if (!$ce->{pg}{ansEvalDefaults}{enableReducedScoring}
			&& ($field eq 'reduced_scoring_date' || $field eq 'enable_reduced_scoring'))
		{
			$properties{'type'} = 'hidden';
		} elsif ($ce->{pg}{ansEvalDefaults}{enableReducedScoring}
			&& $field eq 'reduced_scoring_date'
			&& !$globalRecord->reduced_scoring_date)
		{
			$globalRecord->reduced_scoring_date(
				$globalRecord->due_date - 60 * $ce->{pg}{ansEvalDefaults}{reducedScoringPeriod});
		}

		# We don't show the ip restriction option if there are
		# no defined locations, nor the relax_restrict_ip option
		# if we're not restricting ip access.
		next if ($field eq 'restrict_ip' && (!$numLocations || $setVersion));
		next
			if (
				$field eq 'relax_restrict_ip'
				&& (!$numLocations
					|| $setVersion
					|| ($forUsers  && $userRecord->restrict_ip eq 'No')
					|| (!$forUsers && ($globalRecord->restrict_ip eq '' || $globalRecord->restrict_ip eq 'No')))
			);

		# Skip the problem seed if we are not editing for one user, or if we are editing a gateway set for users,
		# but aren't editing a set version.
		next if ($field eq 'problem_seed' && (!$forOneUser || ($isGWset && $forUsers && !$setVersion)));

		# Skip the status if we are not editing for one user.
		next if ($field eq 'status' && !$forOneUser);

		# Skip the Show Me Another value if SMA is not enabled.
		next if ($field eq 'showMeAnother' && !$ce->{pg}{options}{enableShowMeAnother});

		# Skip the periodic re-randomization field if it is not enabled.
		next if ($field eq 'prPeriod' && !$ce->{pg}{options}{enablePeriodicRandomization});

		unless ($properties{type} eq 'hidden') {
			my @row = $self->fieldHTML($userID, $setID, $problemID, $globalRecord, $userRecord, $field);
			push(@$rows, $r->tag('tr', $r->c(map { $r->tag('td', $_) } @row)->join(''))) if @row > 1;
		}

		# Finally, put in extra fields that are exceptions to the usual display mechanism.
		push(@$rows, $ipFields) if $field eq 'restrict_ip' && $ipFields;

		push(@$rows, $procFields, $extraFields) if $field eq 'assignment_type';
	}

	if (defined $problemID && $forOneUser) {
		my $problemRecord = $userRecord;
		push(
			@$rows,
			$r->include(
				'ContentGenerator/Instructor/ProblemSetDetail/attempts_row',
				problemID     => $problemID,
				problemRecord => $problemRecord
			)
		);
	}

	return $r->tag(
		'table',
		class => 'table table-sm table-borderless align-middle font-sm w-auto mb-0',
		$rows->join('')
	);
}

# Returns a list of information and HTML widgets for viewing and editing the specified db fields.
# If only the setID is included, it creates a list of set information.
# If the problemID is included, it creates a list of problem information.
sub fieldHTML {
	my ($self, $userID, $setID, $problemID, $globalRecord, $userRecord, $field) = @_;

	my $r           = $self->r;
	my $db          = $r->db;
	my @editForUser = $r->param('editForUser');
	my $forUsers    = @editForUser;
	my $forOneUser  = $forUsers == 1;

	return $r->maketext('No data exists for set [_1] and problem [_2]', $setID, $problemID) unless $globalRecord;
	return $r->maketext('No user specific data exists for user [_1]', $userID)
		if $forOneUser && $globalRecord && !$userRecord;

	my %properties = %{ FIELD_PROPERTIES()->{$field} };
	my %labels     = %{ $properties{labels} };

	for my $key (keys %labels) {
		$labels{$key} = $r->maketext($labels{$key});
	}

	return '' if $properties{type} eq 'hidden';
	return '' if $properties{override} eq 'one'  && !$forOneUser;
	return '' if $properties{override} eq 'none' && !$forOneUser;
	return '' if $properties{override} eq 'all'  && $forUsers;

	my $edit   = ($properties{type} eq 'edit')   && ($properties{override} ne 'none');
	my $choose = ($properties{type} eq 'choose') && ($properties{override} ne 'none');

	# FIXME: allow one selector to set multiple fields
	my ($globalValue, $userValue) = ('', '');
	my $blankfield = '';
	if ($field =~ /:/) {
		my @gVals;
		my @uVals;
		my @bVals;
		for my $f (split(/:/, $field)) {
			# Hmm.  This directly references the data in the record rather than calling the access method, thereby
			# avoiding errors if the access method is undefined.  That seems a bit suspect, but it's used below so we'll
			# leave it here.
			push(@gVals, $globalRecord->{$f});
			push(@uVals, $userRecord->{$f});
			push(@bVals, '');
		}
		# I don't like this, but combining multiple values is a bit messy
		$globalValue = (grep {defined} @gVals) ? join(':', (map { defined ? $_ : '' } @gVals)) : undef;
		$userValue   = (grep {defined} @uVals) ? join(':', (map { defined ? $_ : '' } @uVals)) : undef;
		$blankfield  = join(':', @bVals);
	} else {
		$globalValue = $globalRecord->{$field};
		$userValue   = $userRecord->{$field};
	}

	# Use defined instead of value in order to allow 0 to printed, e.g. for the 'value' field.
	$globalValue = defined $globalValue ? ($labels{$globalValue} || $globalValue) : '';
	$userValue   = defined $userValue   ? ($labels{$userValue}   || $userValue)   : $blankfield;

	if ($field =~ /_date/) {
		$globalValue = $self->formatDateTime($globalValue, '', 'datetime_format_short', $r->ce->{language})
			if $forUsers && defined $globalValue && $globalValue ne '';
	}

	if (defined $properties{convertby} && $properties{convertby}) {
		$globalValue = $globalValue / $properties{convertby} if $globalValue;
		$userValue   = $userValue / $properties{convertby}   if $userValue;
	}

	# check to make sure that a given value can be overridden
	my %canOverride = map { $_ => 1 } (@{ PROBLEM_FIELDS() }, @{ SET_FIELDS() });
	my $check       = $canOverride{$field};

	# $recordType is a shorthand in the return statement for problem or set
	# $recordID is a shorthand in the return statement for $problemID or $setID
	my $recordType = '';
	my $recordID   = '';
	if (defined $problemID) {
		$recordType = 'problem';
		$recordID   = $problemID;
	} else {
		$recordType = 'set';
		$recordID   = $setID;
	}

	# $inputType contains either an input box or a popup_menu for changing a given db field
	my $inputType = '';

	if ($edit) {
		if ($field =~ /_date/) {
			$inputType = $r->tag(
				'div',
				class => 'input-group input-group-sm flatpickr',
				$r->c(
					$r->text_field(
						"$recordType.$recordID.$field",
						$forUsers ? $userValue : $globalValue,
						id    => "$recordType.$recordID.${field}_id",
						class => 'form-control form-control-sm'
							. ($field eq 'open_date' ? ' datepicker-group' : ''),
						placeholder => $r->maketext('None Specified'),
						data        => {
							input     => undef,
							done_text => $r->maketext('Done'),
							locale    => $r->ce->{language},
							timezone  => $r->ce->{siteDefaults}{timezone},
							override  => "$recordType.$recordID.$field.override_id"
						},
						$forUsers && $check ? ('aria-labelledby' => "$recordType.$recordID.$field.label") : (),
					),
					$r->tag(
						'a',
						class        => 'btn btn-secondary btn-sm',
						data         => { toggle => undef },
						role         => 'button',
						tabindex     => 0,
						'aria-label' => $r->maketext('Pick date and time'),
						$r->tag('i', class => 'fas fa-calendar-alt', 'aria-hidden' => 'true', '')
					)
				)->join('')
			);
		} else {
			my $value = $forUsers ? $userValue : $globalValue;
			$value = format_set_name_display($value =~ s/\s*,\s*/,/gr) if $field eq 'restricted_release';

			$inputType = $r->text_field(
				"$recordType.$recordID.$field", $value,
				id    => "$recordType.$recordID.${field}_id",
				data  => { override => "$recordType.$recordID.$field.override_id" },
				class => 'form-control form-control-sm',
				$forUsers && $check ? (aria_labelledby => "$recordType.$recordID.$field.label") : (),
				$field eq 'restricted_release' || $field eq 'source_file' ? (dir => 'ltr')      : ()
			);
		}
	} elsif ($choose) {
		# If $field matches /:/, then multiple fields are used.
		my $value = '';
		if (!$value && $field =~ /:/) {
			my @fields = split(/:/, $field);
			my @part_values;
			for (@fields) {
				push(@part_values, $forUsers && $userRecord->$_ ne '' ? $userRecord->$_ : $globalRecord->$_);
			}
			$value = join(':', @part_values);
		} elsif (!$value) {
			$value = ($forUsers && $userRecord->$field ne '' ? $userRecord->$field : $globalRecord->$field);
		}

		$inputType = $r->select_field(
			"$recordType.$recordID.$field", [
				map { [ $labels{$_} => $_, $_ eq $value ? (selected => undef) : () ] } @{ $properties{choices} }
			],
			id    => "$recordType.$recordID.${field}_id",
			data  => { override => "$recordType.$recordID.$field.override_id" },
			class => 'form-select form-select-sm',
			$forUsers && $check ? ('aria-labelledby' => "$recordType.$recordID.$field.label") : (),
		);
	}

	my $gDisplVal =
		(defined $properties{labels} && defined $properties{labels}{$globalValue})
		? $r->maketext($properties{labels}{$globalValue})
		: $globalValue;
	$gDisplVal = format_set_name_display($gDisplVal) if $field eq 'restricted_release';

	my @return;

	push @return,
		(
			$check
			? $r->check_box(
				"$recordType.$recordID.$field.override", $field,
				id    => "$recordType.$recordID.$field.override_id",
				class => 'form-check-input',
				$userValue ne (($labels{''} // '') || $blankfield) ? (checked => undef) : (),
			)
			: ''
		) if $forUsers;

	push @return,
		$r->label_for(
			($forUsers && $check ? "$recordType.$recordID.$field.override_id" : "$recordType.$recordID.${field}_id"),
			$r->maketext($properties{name}),
			$forUsers && $check
			? (class => 'form-check-label mb-0', id => "$recordType.$recordID.$field.label")
			: (class => 'form-label mb-0'),
		);

	push @return,
		$properties{help_text}
		? $r->tag(
			'a',
			class    => 'help-popup',
			role     => 'button',
			tabindex => 0,
			data     => {
				bs_content   => $r->maketext($properties{help_text}),
				bs_placement => 'top',
				bs_toggle    => 'popover'
			},
			$r->tag(
				'i',
				class         => 'icon fas fa-question-circle',
				data          => { alt => $r->maketext('Help Icon') },
				'aria-hidden' => 'true'
			)
		)
		: '';

	push @return, $inputType;

	push @return,
		(
			$gDisplVal ne ''
			? $r->text_field(
				"$recordType.$recordID.$field.class_value",
				$gDisplVal,
				readonly          => undef,
				size              => $properties{size} || 5,
				class             => 'form-control form-control-sm',
				'aria-labelledby' => "$recordType.$recordID.$field.label",
				$field =~ /date/ || $field eq 'restricted_release' || $field eq 'source_file' ? (dir => 'ltr') : ()
			)
			: ''
		) if $forUsers;

	return @return;
}

# Return weird fields that are non-native or which are displayed for only some sets.
sub extraSetFields {
	my ($self, $userID, $setID, $globalRecord, $userRecord, $forUsers) = @_;
	my $db = $self->r->{db};
	my $r  = $self->r;

	my $extraFields = '';

	if ($globalRecord->assignment_type() =~ /gateway/) {
		# If this is a gateway set, set up a table of gateway fields.
		my @gwFields;
		my $num_columns = 0;

		for my $gwfield (@{ GATEWAY_SET_FIELD_ORDER() }) {
			# Don't show template gateway fields when editing set versions.
			next
				if (($gwfield eq "time_interval" || $gwfield eq "versions_per_interval")
					&& ($forUsers && $userRecord->can('version_id')));

			my @fieldData = $self->fieldHTML($userID, $setID, undef, $globalRecord, $userRecord, $gwfield);
			if (@fieldData && defined($fieldData[0]) && $fieldData[0] ne '') {
				$num_columns = @fieldData if @fieldData > $num_columns;
				push(@gwFields, $r->tag('tr', $r->c(map { $r->tag('td', $_) } @fieldData)->join('')));
			}
		}

		$extraFields = $r->c(
			$num_columns
			? $r->tag(
				'tr', $r->tag('td', colspan => $num_columns, $r->tag('em', $r->maketext('Test parameters')))
				)
			: '',
			@gwFields
		)->join('');
	} elsif ($globalRecord->assignment_type eq 'jitar') {
		# If this is a jitar set, set up a table of jitar fields.
		my $num_columns = 0;
		my $jthdr       = '';
		my @jtFields;
		for my $jtfield (@{ JITAR_SET_FIELD_ORDER() }) {
			my @fieldData = $self->fieldHTML($userID, $setID, undef, $globalRecord, $userRecord, $jtfield);
			if (@fieldData && defined($fieldData[0]) && $fieldData[0] ne '') {
				$num_columns = @fieldData if (@fieldData > $num_columns);
				push(@jtFields, $r->tag('tr', $r->c(map { $r->tag('td', $_) } @fieldData)->join('')));
			}
		}
		$extraFields = $r->c(
			$num_columns
			? $r->tag('tr',
				$r->tag('td', colspan => $num_columns, $r->tag('em', $r->maketext('Just-In-Time parameters'))))
			: '',
			@jtFields
		)->join('');
	}

	my $procFields = '';

	# If this is a proctored test, then add a dropdown menu to configure using a grade proctor
	# and a proctored set password input.
	if ($globalRecord->assignment_type eq 'proctored_gateway') {
		$procFields = $r->c(
			# Dropdown menu to configure using a grade proctor.
			$r->tag(
				'tr',
				$r->c(
					map { $r->tag('td', $_) }
						$self->fieldHTML($userID, $setID, undef, $globalRecord, $userRecord, 'use_grade_auth_proctor')
				)->join('')
			),
			$forUsers ? '' : $r->include(
				'ContentGenerator/Instructor/ProblemSetDetail/restricted_login_proctor_password_row',
				globalRecord => $globalRecord
			)
		)->join('');
	}

	# Figure out what ip selector fields to include.
	my @locations    = sort { $a cmp $b } $db->listLocations;
	my $numLocations = @locations;

	my $ipFields = '';

	if (
		(!defined $userRecord || (defined $userRecord && !$userRecord->can('version_id')))
		&& ((!$forUsers && $globalRecord->restrict_ip && $globalRecord->restrict_ip ne 'No')
			|| ($forUsers && $userRecord->restrict_ip ne 'No'))
		)
	{
		my $ipOverride      = 0;
		my @globalLocations = $db->listGlobalSetLocations($setID);

		# Which ip locations should be selected?
		my %defaultLocations;
		if (!$forUsers || !$db->countUserSetLocations($userID, $setID)) {
			%defaultLocations = map { $_ => 1 } @globalLocations;
		} else {
			%defaultLocations = map { $_ => 1 } $db->listUserSetLocations($userID, $setID);
			$ipOverride       = 1;
		}

		$ipFields = $r->include(
			'ContentGenerator/Instructor/ProblemSetDetail/ip_locations_row',
			forUsers         => $forUsers,
			ipOverride       => $ipOverride,
			locations        => \@locations,
			defaultLocations => \%defaultLocations,
			globalLocations  => \@globalLocations
		);
	}
	return ($extraFields, $ipFields, $numLocations, $procFields);
}

# This is a recursive function which displays the tree structure of jitar sets.
# Each child is displayed as a nested ordered list.
sub print_nested_list {
	my ($self, $nestedHash) = @_;
	my $r = $self->r;

	my $output = $r->c;

	# This hash contains information about the problem at this node.  Output the problem row and delete the "id" and
	# "row" keys.  Any remaining keys are references to child nodes which are shown in a sub list via the recursion.
	# Note that the only reason the "id" and "row" keys need to be deleted is because those keys are not numeric for the
	# key sort.
	if (defined $nestedHash->{row}) {
		my $id = delete $nestedHash->{id};
		push(
			@$output,
			$r->tag(
				'li',
				class => 'psd_list_item',
				id    => "psd_list_item_$id",
				$r->c(
					delete $nestedHash->{row},
					$r->tag(
						'ol',
						class => 'sortable-branch collapse',
						id    => "psd_sublist_$id",
						sub {
							my $sub_output = $r->c;
							my @keys       = keys %$nestedHash;
							if (@keys) {
								for (sort { $a <=> $b } @keys) {
									push(@$sub_output, $self->print_nested_list($nestedHash->{$_}));
								}
							}
							return $sub_output->join('');
						}
					)
				)->join('')
			)
		);
	}

	return $output->join('');
}

# Handles rearrangement necessary after changes to problem ordering.
sub handle_problem_numbers {
	my ($self, $newProblemNumbers, $db, $setID) = @_;
	my $r = $self->r;

	# Check to see that everything has a number and if anything was renumbered.
	my $force = 0;
	for my $j (keys %$newProblemNumbers) {
		return ""  if !defined $newProblemNumbers->{$j};
		$force = 1 if $newProblemNumbers->{$j} != $j;
	}

	# we dont do anything unless a problem has been reordered or we were asked to
	return "" unless $force;

	# get problems and store them in a hash.
	# We do this all at once because its not always clear
	# what is overwriting what and when.
	# We try to keep things sane by only getting and storing things
	# which have actually been reordered
	my %problemHash;
	my @setUsers = $db->listSetUsers($setID);
	my %userProblemHash;

	for my $j (keys %$newProblemNumbers) {
		next if $newProblemNumbers->{$j} == $j;

		$problemHash{$j} = $db->getGlobalProblem($setID, $j);
		die $r->maketext("global [_1] for set [_2] not found.", $j, $setID) unless $problemHash{$j};
		foreach my $user (@setUsers) {
			$userProblemHash{$user}{$j} = $db->getUserProblem($user, $setID, $j);
			warn $r->maketext(
				"UserProblem missing for user=[_1] set=[_2] problem=[_3]. This may indicate database corruption.",
				$user, $setID, $j)
				. "\n"
				unless $userProblemHash{$user}{$j};
		}
	}

	# now go through and move problems around
	# because of the way the reordering works with the draggable
	# js handler we cant have any conflicts or holes
	for my $j (keys %$newProblemNumbers) {
		next if ($newProblemNumbers->{$j} == $j);

		$problemHash{$j}->problem_id($newProblemNumbers->{$j});
		if ($db->existsGlobalProblem($setID, $newProblemNumbers->{$j})) {
			$db->putGlobalProblem($problemHash{$j});
		} else {
			$db->addGlobalProblem($problemHash{$j});
		}

		# now deal with the user sets

		foreach my $user (@setUsers) {

			$userProblemHash{$user}{$j}->problem_id($newProblemNumbers->{$j});
			if ($db->existsUserProblem($user, $setID, $newProblemNumbers->{$j})) {
				$db->putUserProblem($userProblemHash{$user}{$j});
			} else {
				$db->addUserProblem($userProblemHash{$user}{$j});
			}

		}

		# now we need to delete "orphan" problems that were not overwritten by something else
		my $delete = 1;
		foreach my $k (keys %$newProblemNumbers) {
			$delete = 0 if ($j == $newProblemNumbers->{$k});
		}

		if ($delete) {
			$db->deleteGlobalProblem($setID, $j);
		}

	}

	# return a string form of the old problem IDs in the new order (not used by caller, incidentally)
	return join(', ', values %$newProblemNumbers);
}

# Primarily saves any changes into the correct set or problem records (global vs user).
# Also deals with deleting or rearranging problems.
sub initialize {
	my ($self) = @_;
	my $r      = $self->r;
	my $db     = $r->db;
	my $ce     = $r->ce;
	my $authz  = $r->authz;
	my $user   = $r->param('user');
	my $setID  = $r->urlpath->arg('setID');

	# Make sure these are defined for the templates.
	$r->stash->{fullSetID}        = $setID;
	$r->stash->{headers}          = HEADER_ORDER();
	$r->stash->{field_properties} = FIELD_PROPERTIES();
	$r->stash->{display_modes}    = WeBWorK::PG::DISPLAY_MODES();
	$r->stash->{unassignedUsers}  = [];
	$r->stash->{problemIDList}    = [];
	$r->stash->{globalProblems}   = {};
	$r->stash->{userProblems}     = {};
	$r->stash->{mergedProblems}   = {};

	# A set may be provided with a version number (as in setID,v#).
	# If so obtain the template set id and version number.
	my $editingSetVersion = 0;
	if ($setID =~ /,v(\d+)$/) {
		$editingSetVersion = $1;
		$setID =~ s/,v(\d+)$//;
	}

	$r->stash->{setID}             = $setID;
	$r->stash->{editingSetVersion} = $editingSetVersion;

	my $setRecord = $db->getGlobalSet($setID);
	$r->stash->{setRecord} = $setRecord;
	return unless $setRecord;

	return unless ($authz->hasPermissions($user, 'access_instructor_tools'));
	return unless ($authz->hasPermissions($user, 'modify_problem_sets'));

	my @editForUser = $r->param('editForUser');

	my $forUsers = scalar(@editForUser);
	$r->stash->{forUsers} = $forUsers;
	my $forOneUser = $forUsers == 1;
	$r->stash->{forOneUser} = $forOneUser;

	# If editing a versioned set, it only makes sense edit it for one user.
	return if ($editingSetVersion && !$forOneUser);

	my %properties = %{ FIELD_PROPERTIES() };

	# Invert the labels hashes.
	my %undoLabels;
	for my $key (keys %properties) {
		%{ $undoLabels{$key} } =
			map { $r->maketext($properties{$key}{labels}{$_}) => $_ } keys %{ $properties{$key}{labels} };
	}

	my ($open_date, $due_date, $answer_date, $reduced_scoring_date);
	my $error = 0;
	if (defined $r->param('submit_changes')) {
		my @names = ("open_date", "due_date", "answer_date", "reduced_scoring_date");

		my %dates;
		for (@names) {
			$dates{$_} = $r->param("set.$setID.$_") || '';
			if (defined $undoLabels{$_}{ $dates{$_} } || !$dates{$_}) {
				$dates{$_} = $setRecord->$_;
			}
		}

		if (!$error) {
			# Make sure dates are numeric.
			($open_date, $due_date, $answer_date, $reduced_scoring_date) = map { $dates{$_} || 0 } @names;

			if ($answer_date < $due_date || $answer_date < $open_date) {
				$self->addbadmessage(
					$r->maketext("Answers cannot be made available until on or after the close date!"));
				$error = $r->param('submit_changes');
			}

			if ($due_date < $open_date) {
				$self->addbadmessage($r->maketext("Answers cannot be due until on or after the open date!"));
				$error = $r->param('submit_changes');
			}

			my $enable_reduced_scoring = $ce->{pg}{ansEvalDefaults}{enableReducedScoring}
				&& (
					defined($r->param("set.$setID.enable_reduced_scoring"))
					? $r->param("set.$setID.enable_reduced_scoring")
					: $setRecord->enable_reduced_scoring);

			if (
				$enable_reduced_scoring
				&& $reduced_scoring_date
				&& ($reduced_scoring_date > $due_date
					|| $reduced_scoring_date < $open_date)
				)
			{
				$self->addbadmessage(
					$r->maketext("The reduced scoring date should be between the open date and close date."));
				$error = $r->param('submit_changes');
			}

			# Make sure the dates are not more than 10 years in the future.
			my $curr_time        = time;
			my $seconds_per_year = 31_556_926;
			my $cutoff           = $curr_time + $seconds_per_year * 10;
			if ($open_date > $cutoff) {
				$self->addbadmessage(
					$r->maketext("Error: open date cannot be more than 10 years from now in set [_1]", $setID));
				$error = $r->param('submit_changes');
			}
			if ($due_date > $cutoff) {
				$self->addbadmessage(
					$r->maketext("Error: close date cannot be more than 10 years from now in set [_1]", $setID));
				$error = $r->param('submit_changes');
			}
			if ($answer_date > $cutoff) {
				$self->addbadmessage(
					$r->maketext("Error: answer date cannot be more than 10 years from now in set [_1]", $setID));
				$error = $r->param('submit_changes');
			}
		}
	}

	if ($error) {
		$self->addbadmessage($r->maketext("No changes were saved!"));
	}

	if (defined $r->param('submit_changes') && !$error) {

		my $oldAssignmentType = $setRecord->assignment_type();

		# Save general set information (including headers)

		if ($forUsers) {
			# Note that we don't deal with the proctor user fields here, with the assumption that it can't be possible
			# to change them for users.
			# FIXME: This is not the most robust treatment of the problem

			my @userRecords = $db->getUserSetsWhere({ user_id => [@editForUser], set_id => $setID });
			# If editing a set version, we want to edit that instead of the userset, so get it too.
			my $userSet    = $userRecords[0];
			my $setVersion = 0;
			if ($editingSetVersion) {
				$setVersion  = $db->getSetVersion($editForUser[0], $setID, $editingSetVersion);
				@userRecords = ($setVersion);
			}

			foreach my $record (@userRecords) {
				foreach my $field (@{ SET_FIELDS() }) {
					next unless canChange($forUsers, $field);
					my $override = $r->param("set.$setID.$field.override");

					if (defined $override && $override eq $field) {

						my $param = $r->param("set.$setID.$field");
						$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
							unless defined $param && $param ne "";

						my $unlabel = $undoLabels{$field}->{$param};
						$param = $unlabel if defined $unlabel;
						if (defined($properties{$field}->{convertby}) && $properties{$field}->{convertby}) {
							$param = $param * $properties{$field}->{convertby};
						}
						# Special case: Does field fill in multiple values?
						if ($field =~ /:/) {
							my @values = split(/:/, $param);
							my @fields = split(/:/, $field);
							for (my $i = 0; $i < @values; $i++) {
								my $f = $fields[$i];
								$record->$f($values[$i]);
							}
						} else {
							$record->$field($param);
						}
					} else {
						if ($field =~ /:/) {
							foreach my $f (split(/:/, $field)) {
								$record->$f(undef);
							}
						} else {
							$record->$field(undef);
						}
					}

				}

				if ($editingSetVersion) {
					$db->putSetVersion($record);
				} else {
					$db->putUserSet($record);
				}
			}

			# Save IP restriction Location information
			# FIXME: it would be nice to have this in the field values hash, so that we don't have to assume that we can
			# override this information for users.

			# Should we allow resetting set locations for set versions?  This requires either putting in a new set of
			# database routines to deal with the versioned setID, or fudging it at this end by manually putting in the
			# versioned ID setID,v#.  Neither of these seems desirable, so for now it's not allowed
			if (!$editingSetVersion) {
				if ($r->param("set.$setID.selected_ip_locations.override")) {
					foreach my $record (@userRecords) {
						my $userID            = $record->user_id;
						my @selectedLocations = $r->param("set.$setID.selected_ip_locations");
						my @userSetLocations  = $db->listUserSetLocations($userID, $setID);
						my @addSetLocations   = ();
						my @delSetLocations   = ();
						foreach my $loc (@selectedLocations) {
							push(@addSetLocations, $loc) if (!grep {/^$loc$/} @userSetLocations);
						}
						foreach my $loc (@userSetLocations) {
							push(@delSetLocations, $loc) if (!grep {/^$loc$/} @selectedLocations);
						}
						# Update the user set_locations
						foreach (@addSetLocations) {
							my $Loc = $db->newUserSetLocation;
							$Loc->set_id($setID);
							$Loc->user_id($userID);
							$Loc->location_id($_);
							$db->addUserSetLocation($Loc);
						}
						foreach (@delSetLocations) {
							$db->deleteUserSetLocation($userID, $setID, $_);
						}
					}
				} else {
					# If override isn't selected, then make sure that there are no set_locations_user entries.
					foreach my $record (@userRecords) {
						my $userID        = $record->user_id;
						my @userLocations = $db->listUserSetLocations($userID, $setID);
						foreach (@userLocations) {
							$db->deleteUserSetLocation($userID, $setID, $_);
						}
					}
				}
			}
		} else {
			foreach my $field (@{ SET_FIELDS() }) {
				next unless canChange($forUsers, $field);

				my $param = $r->param("set.$setID.$field");
				$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
					unless defined $param && $param ne "";
				my $unlabel = $undoLabels{$field}->{$param};
				$param = $unlabel if defined $unlabel;
				if ($field =~ /restricted_release/ && $param) {
					$param = format_set_name_internal($param =~ s/\s*,\s*/,/gr);
					$self->check_sets($db, $param);
				}
				if (defined($properties{$field}->{convertby}) && $properties{$field}->{convertby} && $param) {
					$param = $param * $properties{$field}->{convertby};
				}

				if ($field =~ /:/) {
					my @values = split(/:/, $param);
					my @fields = split(/:/, $field);
					for (my $i = 0; $i < @fields; $i++) {
						my $f = $fields[$i];
						$setRecord->$f($values[$i]);
					}
				} else {
					$setRecord->$field($param);
				}
			}
			$db->putGlobalSet($setRecord);

			# Save IP restriction Location information
			if (defined($r->param("set.$setID.restrict_ip")) and $r->param("set.$setID.restrict_ip") ne 'No') {
				my @selectedLocations  = $r->param("set.$setID.selected_ip_locations");
				my @globalSetLocations = $db->listGlobalSetLocations($setID);
				my @addSetLocations    = ();
				my @delSetLocations    = ();
				foreach my $loc (@selectedLocations) {
					push(@addSetLocations, $loc) if (!grep {/^$loc$/} @globalSetLocations);
				}
				foreach my $loc (@globalSetLocations) {
					push(@delSetLocations, $loc) if (!grep {/^$loc$/} @selectedLocations);
				}
				# Update the global set_locations
				foreach (@addSetLocations) {
					my $Loc = $db->newGlobalSetLocation;
					$Loc->set_id($setID);
					$Loc->location_id($_);
					$db->addGlobalSetLocation($Loc);
				}
				foreach (@delSetLocations) {
					$db->deleteGlobalSetLocation($setID, $_);
				}
			} else {
				my @globalSetLocations = $db->listGlobalSetLocations($setID);
				foreach (@globalSetLocations) {
					$db->deleteGlobalSetLocation($setID, $_);
				}
			}

			# Save proctored problem proctor user information
			if ($r->param("set.$setID.restricted_login_proctor_password")
				&& $setRecord->assignment_type eq 'proctored_gateway')
			{
				# In this case add a set-level proctor or update the password.
				my $procID = "set_id:$setID";
				my $pass   = $r->param("set.$setID.restricted_login_proctor_password");
				# Should we carefully check in this case that the user and password exist?  The code in the add stanza
				# is pretty careful to be sure that there's a one-to-one correspondence between the existence of the
				# user and the setting of the set restricted_login_proctor field, so we assume that just checking the
				# latter here is sufficient.
				if ($setRecord->restricted_login_proctor eq 'Yes' && $pass ne '********') {
					# A new password was submitted. So save it.
					my $dbPass = eval { $db->getPassword($procID) };
					if ($@) {
						$self->addbadmessage($r->maketext(
							'Error getting old set-proctor password from the database: [_1].  '
								. 'No update to the password was done.',
							$@
						));
					} else {
						$dbPass->password(cryptPassword($pass));
						$db->putPassword($dbPass);
					}
				} else {
					$setRecord->restricted_login_proctor('Yes');
					my $procUser = $db->newUser();
					$procUser->user_id($procID);
					$procUser->last_name("Proctor");
					$procUser->first_name("Login");
					$procUser->student_id("loginproctor");
					$procUser->status($ce->status_name_to_abbrevs('Proctor'));
					my $procPerm = $db->newPermissionLevel;
					$procPerm->user_id($procID);
					$procPerm->permission($ce->{userRoles}{login_proctor});
					my $procPass = $db->newPassword;
					$procPass->user_id($procID);
					$procPass->password(cryptPassword($pass));

					eval { $db->addUser($procUser) };
					if ($@) {
						$self->addbadmessage($r->maketext("Error adding set-level proctor: [_1]", $@));
					} else {
						$db->addPermissionLevel($procPerm);
						$db->addPassword($procPass);
					}

					# Set the restricted_login_proctor set field
					$db->putGlobalSet($setRecord);
				}

			} else {
				# If the parameter isn't set, or if the assignment type is not 'proctored_gateway', then ensure that
				# there is no set-level proctor defined.
				if ($setRecord->restricted_login_proctor eq 'Yes') {

					$setRecord->restricted_login_proctor('No');
					$db->deleteUser("set_id:$setID");
					$db->putGlobalSet($setRecord);

				}
			}
		}

		# Save problem information

		my @problemIDs     = map { $_->[1] } $db->listGlobalProblemsWhere({ set_id => $setID }, 'problem_id');
		my @problemRecords = $db->getGlobalProblems(map { [ $setID, $_ ] } @problemIDs);
		foreach my $problemRecord (@problemRecords) {
			my $problemID = $problemRecord->problem_id;
			die $r->maketext("Global problem [_1] for set [_2] not found.", $problemID, $setID) unless $problemRecord;

			if ($forUsers) {
				# Since we're editing for specific users, we don't allow the GlobalProblem record to be altered on that
				# same page So we only need to make changes to the UserProblem record and only then if we are overriding
				# a value in the GlobalProblem record or for fields unique to the UserProblem record.

				my @userIDs = @editForUser;

				my @userProblemRecords;
				if (!$editingSetVersion) {
					my @userProblemIDs = map { [ $_, $setID, $problemID ] } @userIDs;
					@userProblemRecords = $db->getUserProblemsWhere(
						{ user_id => [@userIDs], set_id => $setID, problem_id => $problemID });
				} else {
					## (we know that we're only editing for one user)
					@userProblemRecords =
						($db->getMergedProblemVersion($userIDs[0], $setID, $editingSetVersion, $problemID));
				}

				foreach my $record (@userProblemRecords) {
					my $changed = 0;    # Keep track of changes. If none are made, avoid unnecessary db accesses.

					for my $field (@{ PROBLEM_FIELDS() }) {
						next unless canChange($forUsers, $field);

						my $override = $r->param("problem.$problemID.$field.override");
						if (defined $override && $override eq $field) {

							my $param = $r->param("problem.$problemID.$field");
							$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
								unless defined $param && $param ne "";
							my $unlabel = $undoLabels{$field}->{$param};
							$param = $unlabel if defined $unlabel;
							# Protect exploits with source_file
							if ($field eq 'source_file') {
								if ($param =~ /\.\./ || $param =~ /^\//) {
									$self->addbadmessage($r->maketext(
										'Source file paths cannot include .. or start with /: '
											. 'your source file path was modified.'
									));
								}
								$param =~ s|\.\.||g;    # prevent access to files above template
								$param =~ s|^/||;       # prevent access to files above template
							}

							$changed ||= changed($record->$field, $param);
							$record->$field($param);
						} else {
							$changed ||= changed($record->$field, undef);
							$record->$field(undef);
						}
					}

					for my $field (@{ USER_PROBLEM_FIELDS() }) {
						next unless canChange($forUsers, $field);

						my $param = $r->param("problem.$problemID.$field");
						$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
							unless defined $param && $param ne "";
						my $unlabel = $undoLabels{$field}->{$param};
						$param = $unlabel if defined $unlabel;
						# Protect exploits with source_file
						if ($field eq 'source_file') {
							if ($param =~ /\.\./ || $param =~ /^\//) {
								$self->addbadmessage($r->maketext(
									'Source file paths cannot include .. or start with /: '
										. 'your source file path was modified.'
								));
							}
							$param =~ s|\.\.||g;    # prevent access to files above template
							$param =~ s|^/||;       # prevent access to files above template
						}

						$changed ||= changed($record->$field, $param);
						$record->$field($param);
					}

					if (!$editingSetVersion) {
						$db->putUserProblem($record) if $changed;
					} else {
						$db->putProblemVersion($record) if $changed;
					}
				}
			} else {
				# Since we're editing for ALL set users, we will make changes to the GlobalProblem record.
				# We may also have instances where a field is unique to the UserProblem record but we want
				# all users to (at least initially) have the same value

				# This only edits a globalProblem record
				my $changed = 0;    # Keep track of changes. If none are made, avoid unnecessary db accesses.
				foreach my $field (@{ PROBLEM_FIELDS() }) {
					next unless canChange($forUsers, $field);

					my $param = $r->param("problem.$problemID.$field");
					$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
						unless defined $param && $param ne "";
					my $unlabel = $undoLabels{$field}->{$param};
					$param = $unlabel if defined $unlabel;

					# Protect exploits with source_file
					if ($field eq 'source_file') {
						if ($param =~ /\.\./ || $param =~ /^\//) {
							$self->addbadmessage($r->maketext(
								'Source file paths cannot include .. or start with /: '
									. 'your source file path was modified.'
							));
						}
						$param =~ s|\.\.||g;    # prevent access to files above template
						$param =~ s|^/||;       # prevent access to files above template
					}
					$changed ||= changed($problemRecord->$field, $param);
					$problemRecord->$field($param);
				}
				$db->putGlobalProblem($problemRecord) if $changed;

				# Sometimes (like for status) we might want to change an attribute in the userProblem record for every
				# assigned user.  However, since this data is stored in the UserProblem records, it won't be displayed
				# once its been changed, and if you hit "Save Changes" again it gets erased.  So we'll enforce that
				# there be something worth putting in all the UserProblem records.  This also will make hitting "Save
				# Changes" on the global page MUCH faster.
				my %useful;
				foreach my $field (@{ USER_PROBLEM_FIELDS() }) {
					my $param = $r->param("problem.$problemID.$field");
					$useful{$field} = 1 if defined $param and $param ne "";
				}

				if (keys %useful) {
					my @userProblemRecords = $db->getUserProblemsWhere({ set_id => $setID, problem_id => $problemID });
					foreach my $record (@userProblemRecords) {
						my $changed = 0;    # Keep track of changes. If none are made, avoid unnecessary db accesses.
						foreach my $field (keys %useful) {
							next unless canChange($forUsers, $field);

							my $param = $r->param("problem.$problemID.$field");
							$param = defined $properties{$field}->{default} ? $properties{$field}->{default} : ""
								unless defined $param && $param ne "";
							my $unlabel = $undoLabels{$field}->{$param};
							$param = $unlabel if defined $unlabel;
							$changed ||= changed($record->$field, $param);
							$record->$field($param);
						}
						$db->putUserProblem($record) if $changed;
					}
				}
			}
		}

		# Mark the specified problems as correct for all users (not applicable when editing a set version, because this
		# only shows up when editing for users or editing the global set/problem, not for one user)
		for my $problemID ($r->param('markCorrect')) {
			my @userProblemIDs =
				$forUsers
				? (map { [ $_, $setID, $problemID ] } @editForUser)
				: $db->listUserProblemsWhere({ set_id => $setID, problem_id => $problemID });
			# If the set is not a gateway set, this requires going through the user_problems and resetting their status.
			# If it's a gateway set, then we have to go through every *version* of every user_problem.  It may be that
			# there is an argument for being able to get() all problem versions for all users in one database call.  The
			# current code may be slow for large classes.
			if ($setRecord->assignment_type !~ /gateway/) {
				my @userProblemRecords = $db->getUserProblems(@userProblemIDs);
				foreach my $record (@userProblemRecords) {
					if (defined $record && ($record->status eq "" || $record->status < 1)) {
						$record->status(1);
						$record->attempted(1);
						$db->putUserProblem($record);
					}
				}
			} else {
				my @userIDs = $forUsers ? @editForUser : $db->listProblemUsers($setID, $problemID);
				foreach my $uid (@userIDs) {
					my @versions = $db->listSetVersions($uid, $setID);
					my @userProblemVersionIDs =
						map { [ $uid, $setID, $_, $problemID ] } @versions;
					my @userProblemVersionRecords = $db->getProblemVersions(@userProblemVersionIDs);
					foreach my $record (@userProblemVersionRecords) {
						if (defined $record && ($record->status eq "" || $record->status < 1)) {
							$record->status(1);
							$record->attempted(1);
							$db->putProblemVersion($record);
						}
					}
				}
			}
		}

		# Delete all problems marked for deletion (not applicable when editing for users).
		foreach my $problemID ($r->param('deleteProblem')) {
			$db->deleteGlobalProblem($setID, $problemID);

			# If it is a jitar, then delete all of the child problems.
			if ($setRecord->assignment_type eq 'jitar') {
				my @ids        = $db->listGlobalProblems($setID);
				my @problemSeq = jitar_id_to_seq($problemID);
			ID: foreach my $id (@ids) {
					my @seq = jitar_id_to_seq($id);
					# Check and see if this is a child.
					next unless $#seq > $#problemSeq;
					for (my $i = 0; $i <= $#problemSeq; $i++) {
						next ID unless $seq[$i] == $problemSeq[$i];
					}
					$db->deleteGlobalProblem($setID, $id);
				}

			}
		}

		# Change problem_ids from regular style to jitar style if appropraite.  (Not applicable when editing for users.)
		# This is a very long operation because we are shuffling the whole database around.
		if ($oldAssignmentType ne $setRecord->assignment_type
			&& ($oldAssignmentType eq 'jitar' || $setRecord->assignment_type eq 'jitar'))
		{
			my %newProblemNumbers;
			my @ids = $db->listGlobalProblems($setID);
			my $i   = 1;
			foreach my $id (@ids) {

				if ($setRecord->assignment_type eq 'jitar') {
					$newProblemNumbers{$id} = seq_to_jitar_id(($id));
				} else {
					$newProblemNumbers{$id} = $i;
					$i++;
				}
			}

			# we dont want to confuse the script by changing the problem
			# ids out from under it so remove the params
			foreach my $id (@ids) {
				$r->param("prob_num_$id", undef);
			}

			handle_problem_numbers($self, \%newProblemNumbers, $db, $setID);
		}

		# Reorder problems

		my %newProblemNumbers;
		my $prevNum = 0;
		my @prevSeq = (0);

		for my $jj (sort { $a <=> $b } $db->listGlobalProblems($setID)) {
			if ($setRecord->assignment_type eq 'jitar') {
				my @idSeq;
				my $id = $jj;

				next unless $r->param('prob_num_' . $id);

				unshift @idSeq, $r->param('prob_num_' . $id);
				while (defined $r->param('prob_parent_id_' . $id)) {
					$id = $r->param('prob_parent_id_' . $id);
					unshift @idSeq, $r->param('prob_num_' . $id);
				}

				$newProblemNumbers{$jj} = seq_to_jitar_id(@idSeq);

			} else {
				$newProblemNumbers{$jj} = $r->param('prob_num_' . $jj);
			}
		}

		handle_problem_numbers($self, \%newProblemNumbers, $db, $setID) unless defined $r->param('undo_changes');

		# Make problem numbers consecutive if required
		if ($r->param('force_renumber')) {
			my %newProblemNumbers = ();
			my $prevNum           = 0;
			my @prevSeq           = (0);

			for my $jj (sort { $a <=> $b } $db->listGlobalProblems($setID)) {
				if ($setRecord->assignment_type eq 'jitar') {
					my @idSeq;
					my $id = $jj;

					next unless $r->param('prob_num_' . $id);

					unshift @idSeq, $r->param('prob_num_' . $id);
					while (defined $r->param('prob_parent_id_' . $id)) {
						$id = $r->param('prob_parent_id_' . $id);
						unshift @idSeq, $r->param('prob_num_' . $id);
					}

					# we dont really care about the content of idSeq
					# in this case, just the length
					my $depth = $#idSeq;

					if ($depth <= $#prevSeq) {
						@prevSeq = @prevSeq[ 0 .. $depth ];
						++$prevSeq[-1];
					} else {
						$prevSeq[ $#prevSeq + 1 ] = 1;
					}

					$newProblemNumbers{$jj} = seq_to_jitar_id(@prevSeq);

				} else {
					$prevNum++;
					$newProblemNumbers{$jj} = $prevNum;
				}
			}

			handle_problem_numbers($self, \%newProblemNumbers, $db, $setID) unless defined $r->param('undo_changes');
		}

		# Add blank problem if needed
		if (defined($r->param("add_blank_problem")) and $r->param("add_blank_problem") == 1) {
			# Get number of problems to add and clean the entry
			my $newBlankProblems = (defined($r->param("add_n_problems"))) ? $r->param("add_n_problems") : 1;
			$newBlankProblems = int($newBlankProblems);
			my $MAX_NEW_PROBLEMS = 20;
			my @ids              = $self->r->db->listGlobalProblems($setID);

			if ($setRecord->assignment_type eq 'jitar') {
				for (my $i = 0; $i <= $#ids; $i++) {
					my @seq = jitar_id_to_seq($ids[$i]);
					# This strips off the depth 0 problem numbers if its a jitar set
					$ids[$i] = $seq[0];
				}
			}

			my $targetProblemNumber = WeBWorK::Utils::max(@ids);

			if ($newBlankProblems >= 1 and $newBlankProblems <= $MAX_NEW_PROBLEMS) {
				foreach my $newProb (1 .. $newBlankProblems) {
					$targetProblemNumber++;
					# Make local copy of the blankProblem
					my $blank_file_path = $ce->{webworkFiles}{screenSnippets}{blankProblem};
					my $problemContents = WeBWorK::Utils::readFile($blank_file_path);
					my $new_file_path   = "set$setID/" . BLANKPROBLEM();
					my $fullPath = WeBWorK::Utils::surePathToFile($ce->{courseDirs}{templates}, '/' . $new_file_path);

					open(my $TEMPFILE, '>', $fullPath) or warn $r->maketext(q{Can't write to file [_1]}, $fullPath);
					print $TEMPFILE $problemContents;
					close($TEMPFILE);

					# Update problem record
					my $problemRecord = addProblemToSet(
						$db, $ce->{problemDefaults},
						setName    => $setID,
						sourceFile => $new_file_path,
						problemID  => $setRecord->assignment_type eq 'jitar'
						? seq_to_jitar_id(($targetProblemNumber))
						: $targetProblemNumber,
					);

					assignProblemToAllSetUsers($db, $problemRecord);
					$self->addgoodmessage($r->maketext(
						"Added [_1] to [_2] as problem [_3]",
						$new_file_path, $setID, $targetProblemNumber
					));
				}
			} else {
				$self->addbadmessage($r->maketext(
					"Could not add [_1] problems to this set.  The number must be between 1 and [_2]",
					$newBlankProblems, $MAX_NEW_PROBLEMS
				));
			}
		}

		# Sets the specified header to "defaultHeader" so that the default file will get used.
		foreach my $header ($r->param('defaultHeader')) {
			$setRecord->$header("defaultHeader");
		}
	}

	# Check that every user that that is being editing for has a valid UserSet.
	my @unassignedUsers;
	if (@editForUser) {
		my @assignedUsers;
		for my $ID (@editForUser) {
			if ($db->getUserSet($ID, $setID)) {
				unshift @assignedUsers, $ID;
			} else {
				unshift @unassignedUsers, $ID;
			}
		}
		@editForUser = sort @assignedUsers;
		$r->param('editForUser', \@editForUser);
	}

	$r->stash->{unassignedUsers} = \@unassignedUsers;

	# Check that if a set version for a user is being edited, that it exists as well
	return if $editingSetVersion && !$db->existsSetVersion($editForUser[0], $setID, $editingSetVersion);

	# Get global problem records for all problems sorted by problem id.
	my @globalProblems = $db->getGlobalProblemsWhere({ set_id => $setID }, 'problem_id');
	$r->stash->{problemIDList}  = [ map { $_->problem_id } @globalProblems ];
	$r->stash->{globalProblems} = { map { $_->problem_id => $_ } @globalProblems };

	# If editing for one user, get user problem records for all problems also sorted by problem_id.
	if (@editForUser == 1) {
		$r->stash->{userProblems} = { map { $_->problem_id => $_ }
				$db->getUserProblemsWhere({ user_id => $editForUser[0], set_id => $setID }, 'problem_id') };

		if ($editingSetVersion) {
			$r->stash->{mergedProblems} = {
				map { $_->problem_id => $_ } $db->getMergedProblemVersionsWhere(
					{ user_id => $editForUser[0], set_id => { like => "$setID,v\%" } }, 'problem_id'
				)
			};
		} else {
			$r->stash->{mergedProblems} = { map { $_->problem_id => $_ }
					$db->getMergedProblemsWhere({ user_id => $editForUser[0], set_id => $setID }, 'problem_id') };
		}
	}

	# Reset all the parameters dealing with set/problem/header information.  It may not be obvious why this is necessary
	# when saving changes, but when the problems are reordered the param problem.1.source_file needs to be the source
	# file of the problem that is NOW #1 and not the problem that WAS #1.
	for my $param ($r->param) {
		$r->param($param, undef) if $param =~ /^(set|problem|header)\./ && $param !~ /displaymode/;
	}

	# Reset checkboxes that should always be unchecked when the page loads.
	$r->param('deleteProblem',     undef);
	$r->param('markCorrect',       undef);
	$r->param('force_renumber',    undef);
	$r->param('add_blank_problem', undef);

	return;
}

# Helper method for checking if two values are different.
# The return values will usually be thrown away, but they could be useful for debugging.
sub changed {
	my ($first, $second) = @_;

	return "def/undef" if defined $first  && !defined $second;
	return "undef/def" if !defined $first && defined $second;
	return ""          if !defined $first && !defined $second;
	return "ne"        if $first ne $second;
	return "";
}

# Helper method that determines for how many users at a time a field can be changed.
# 	none means it can't be changed for anyone
# 	any means it can be changed for anyone
# 	one means it can ONLY be changed for one at a time. (eg problem_seed)
# 	all means it can ONLY be changed for all at a time. (eg set_header)
sub canChange {
	my ($forUsers, $field) = @_;

	my %properties = %{ FIELD_PROPERTIES() };
	my $forOneUser = $forUsers == 1;

	my $howManyCan = $properties{$field}{override};
	return 0 if $howManyCan eq "none";
	return 1 if $howManyCan eq "any";
	return 1 if $howManyCan eq "one" && $forOneUser;
	return 1 if $howManyCan eq "all" && !$forUsers;
	return 0;    # FIXME: maybe it should default to 1?
}

# Helper method that determines if a file is valid and returns a pretty error message.
sub checkFile {
	my ($self, $filePath, $headerType) = @_;

	my $r  = $self->r;
	my $ce = $r->ce;

	return $r->maketext("No source filePath specified") unless $filePath;
	return $r->maketext("Problem source is drawn from a grouping set") if $filePath =~ /^group/;

	if ($filePath eq "defaultHeader") {
		if ($headerType eq 'set_header') {
			$filePath = $ce->{webworkFiles}{screenSnippets}{setHeader};
		} elsif ($headerType eq 'hardcopy_header') {
			$filePath = $ce->{webworkFiles}{hardcopySnippets}{setHeader};
		} else {
			return $r->maketext("Invalid headerType [_1]", $headerType);
		}
	} else {
		# Only filePaths in the template directory can be accessed.
		$filePath = "$ce->{courseDirs}{templates}/$filePath";
	}

	my $fileError;
	return ""                                                if -e $filePath && -f $filePath && -r $filePath;
	return $r->maketext("This source file is not readable!") if -e $filePath && -f $filePath;
	return $r->maketext("This source file is a directory!")  if -d $filePath;
	return $r->maketext("This source file does not exist!") unless -e $filePath;
	return $r->maketext("This source file is not a plain file!");
}

# Make sure restrictor sets exist.
sub check_sets {
	my ($self, $db, $sets_string) = @_;
	my @proposed_sets = split(/\s*,\s*/, $sets_string);
	foreach (@proposed_sets) {
		$self->addbadmessage("Error: $_ is not a valid set name in restricted release list!")
			unless $db->existsGlobalSet($_);
	}

	return;
}

sub userCountMessage {
	my ($self, $count, $numUsers) = @_;
	my $r = $self->r;

	if ($count == 0) {
		return $r->tag('em', $r->maketext('no students'));
	} elsif ($count == $numUsers) {
		return $r->maketext('all students');
	} elsif ($count == 1) {
		return $r->maketext('1 student');
	} elsif ($count > $numUsers || $count < 0) {
		return $r->tag('em', $r->maketext('an impossible number of users: [_1] out of [_2]', $count, $numUsers));
	} else {
		return $r->maketext('[_1] students out of [_2]', $count, $numUsers);
	}
}

sub setCountMessage {
	my ($self, $count, $numSets) = @_;
	my $r = $self->r;

	if ($count == 0) {
		return $r->tag('em', $r->maketext('no sets'));
	} elsif ($count == $numSets) {
		return $r->maketext('all sets');
	} elsif ($count == 1) {
		return $r->maketext('1 set');
	} elsif ($count > $numSets || $count < 0) {
		return $r->tag('em', $self->r->maketext('an impossible number of sets: [_1] out of [_2]', $count, $numSets));
	} else {
		return $r->maketext('[_1] sets', $count);
	}
}

1;
