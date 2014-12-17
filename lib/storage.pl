/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2014, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(web_storage, []).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/mimetype)).
:- use_module(library(settings)).
:- use_module(library(random)).
:- use_module(library(apply)).
:- use_module(library(option)).
:- use_module(library(debug)).

:- use_module(page).
:- use_module(gitty).
:- use_module(config).

/** <module> Store files on behalve of web clients

The file store needs to deal  with   versioning  and  meta-data. This is
achieved using gitty.pl, a git-like content-base  store that lacks git's
notion of a _tree_. I.e., all files   are considered individual and have
their own version.
*/

:- setting(directory, atom, storage, 'The directory for storing files.').

:- http_handler(swish(p), web_storage, [ id(web_storage), prefix ]).

%%	web_storage(+Request) is det.
%
%	Restfull HTTP handler to store data on behalf of the client in a
%	hard-to-guess location. Returns a JSON  object that provides the
%	URL for the data and the plain   file name. Understands the HTTP
%	methods =GET=, =POST=, =PUT= and =DELETE=.

web_storage(Request) :-
	option(method(Method), Request),
	storage(Method, Request).

storage(get, Request) :-
	http_parameters(Request,
			[ format(Format, [ oneof([swish,raw]),
					   default(swish),
					   description('How to render')
					 ])
			]),
	storage_get(Request, Format).
storage(post, Request) :-
	http_read_json_dict(Request, Dict),
	option(data(Data), Dict, ""),
	option(type(Type), Dict, pl),
	meta_data(Request, Dict, Meta),
	setting(directory, Dir),
	make_directory_path(Dir),
	(   Base = Dict.get(meta).get(name)
	->  file_name_extension(Base, Type, File),
	    (	catch(gitty_create(Dir, File, Data, Meta, Commit),
		      error(gitty(file_exists(File)),_),
		      fail)
	    ->	true
	    ;	Error = json{error:file_exists,
			     file:File}
	    )
	;   (   repeat,
	        random_filename(Base),
		file_name_extension(Base, Type, File),
		catch(gitty_create(Dir, File, Data, Meta, Commit),
		      error(gitty(file_exists(File)),_),
		      fail)
	    ->  true
	    )
	),
	(   var(Error)
	->  debug(storage, 'Created: ~p', [Commit]),
	    storage_url(File, URL),
	    reply_json_dict(json{url:URL, file:File, meta:Meta})
	;   reply_json_dict(Error)
	).
storage(put, Request) :-
	http_read_json_dict(Request, Dict),
	option(data(Data), Dict, ""),
	meta_data(Request, Dict, Meta),
	setting(directory, Dir),
	request_file(Request, Dir, File),
	storage_url(File, URL),
	gitty_update(Dir, File, Data, Meta, Commit),
	debug(storage, 'Updated: ~p', [Commit]),
	reply_json_dict(json{url:URL, file:File, meta:Meta}).
storage(delete, Request) :-
	authentity(Request, Meta),
	setting(directory, Dir),
	request_file(Request, Dir, File),
	gitty_update(Dir, File, "", Meta, _New),
	reply_json_dict(true).

request_file(Request, Dir, File) :-
	option(path_info(PathInfo), Request),
	atom_concat(/, File, PathInfo),
	(   gitty_file(Dir, File, _Hash)
	->  true
	;   http_404([], Request)
	).

storage_url(File, HREF) :-
	http_link_to_id(web_storage, path_postfix(File), HREF).

%%	meta_data(+Request, +Dict, -Meta) is det.
%
%	Gather meta-data from the  Request   (user,  peer)  and provided
%	meta-data. Illegal and unknown values are ignored.

meta_data(Request, Dict, Meta) :-
	authentity(Request, Meta0),	% user, peer
	(   filter_meta(Dict.get(meta), Meta1)
	->  Meta = Meta0.put(Meta1)
	;   Meta = Meta0
	).

filter_meta(Dict0, Dict) :-
	dict_pairs(Dict0, Tag, Pairs0),
	filter_pairs(Pairs0, Pairs),
	dict_pairs(Dict, Tag, Pairs).

filter_pairs([], []).
filter_pairs([H|T0], [H|T]) :-
	H = K-V,
	meta_allowed(K, Type),
	is_of_type(Type, V), !,
	filter_pairs(T0, T).
filter_pairs([_|T0], T) :-
	filter_pairs(T0, T).

meta_allowed(public,      boolean).
meta_allowed(author,      string).
meta_allowed(email,       string).
meta_allowed(title,       string).
meta_allowed(keywords,    list(string)).
meta_allowed(description, string).


%%	storage_get(+Request, +Format) is det.

storage_get(Request, swish) :-
	swish_reply_config(Request), !.
storage_get(Request, swish) :- !,
	setting(directory, Dir),
	request_file(Request, Dir, File),
	gitty_data(Dir, File, Code, Meta),
	swish_reply([code(Code),file(File),meta(Meta)], Request).
storage_get(Request, _) :-
	setting(directory, Dir),
	request_file(Request, Dir, File),
	gitty_data(Dir, File, Code, _Meta),
	file_mime_type(File, MIME),
	format('Content-type: ~w~n~n', [MIME]),
	format('~s', [Code]).


%%	authentity(+Request, -Authentity:dict) is det.
%
%	Provide authentication meta-information.  Currently user by
%	exploiting the pengine authentication hook and peer.

authentity(Request, Authentity) :-
	phrase(authentity(Request), Pairs),
	dict_pairs(Authentity, _, Pairs).

authentity(Request) -->
	(user(Request)->[];[]),
	(peer(Request)->[];[]).

:- multifile
	pengines:authentication_hook/3.

user(Request) -->
	{ pengines:authentication_hook(Request, swish, User),
	  ground(User)
	},
	[ user-User ].
peer(Request) -->
	{ http_peer(Request, Peer) },
	[ peer-Peer ].

%%	random_filename(-Name) is det.
%
%	Return a random file name from plain nice ASCII characters.

random_filename(Name) :-
	length(Chars, 8),
	maplist(random_char, Chars),
	atom_chars(Name, Chars).

from('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ').

random_char(Char) :-
	from(From),
	atom_length(From, Len),
	Max is Len - 1,
	random_between(0, Max, I),
	sub_atom(From, I, 1, _, Char).
