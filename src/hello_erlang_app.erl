-module(hello_erlang_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    Dispatch = cowboy_router:compile(
		 [
		  {'_', [{"/", cowboy_static, {priv_file, hello_erlang, "index.html"}},
			 {"/test", cowboy_static, {priv_file, hello_erlang, "test.html"}},
			 {"/treebear/spark", spark_handler, []},
			 {"/assets/[...]", cowboy_static, {priv_dir, hello_erlang, "static/assets"}}
			]
		  }
		 ]
		),
    {ok, _} = cowboy:start_http(my_http_listener, 100, [{port, 8080}],
				[{env, [{dispatch, Dispatch}]}]
			       ),
    hello_erlang_sup:start_link().

stop(_State) ->
    ok.
