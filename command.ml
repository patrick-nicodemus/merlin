type state = State.t = {
  pos      : Lexing.position;
  tokens   : Outline.token list;
  outlines : Outline.t;
  chunks   : Chunk.t;
  types    : Typer.t;
}

type handler = Protocol.io -> state -> Json.json list -> state * Json.json
type t = { name : string ; handler : handler }
let invalid_arguments () = failwith "invalid arguments"

let commands : (string,t) Hashtbl.t = Hashtbl.create 11
let register cmd = Hashtbl.add commands cmd.name cmd

let command_tell = {
  name = "tell";

  handler = begin fun (i,o) state -> function
  | [`String "struct" ; `String source] ->
      Env.reset_missing_cmis ();
      let eod = ref false and eot = ref false in
      let lexbuf = Misc.lex_strings source
        begin fun () ->
          if !eot then ""
          else try
            o (Protocol.return (`Bool false));
            match Stream.next i with
            | `List [`String "tell" ; `String "struct" ; `String source] ->
              source
            | `List [`String "tell" ; `String "end" ; `String source] ->
              eod := true; source
            | `List [`String "tell" ; `String ("end"|"struct") ; `Null] ->
              eot := true; ""
            | _ -> (* FIXME: parser catch this Failure. It should not *)
              invalid_arguments ()
          with
            Stream.Failure -> invalid_arguments ()
        end
      in
      let rec loop state =
        let bufpos = ref state.pos in
        let tokens, outlines, chunks, types =
          state.tokens,
          (History.cutoff state.outlines),
          (History.cutoff state.chunks),
          (History.cutoff state.types)
        in
        let exns, tokens, outlines =
          match Location.catch_warnings 
              (fun () -> Outline.parse ~bufpos tokens outlines lexbuf)
          with
          | warnings, Misc.Inr (tokens, outlines) -> 
            warnings, tokens, outlines
          | warnings, Misc.Inl exn -> 
            exn :: warnings, tokens, outlines
        in
        let outlines = Outline.append_exns exns outlines in
        let chunks = Chunk.sync outlines chunks in
        let types = Typer.sync chunks types in
        let pos = !bufpos in
          (* If token list didn't change, move forward anyway 
           * to prevent getting stuck *)
        let stuck = state.tokens = tokens in
        let tokens =
          if stuck
          then (try List.tl tokens with _ -> tokens)
          else tokens
        in
        let state' = { tokens ; outlines ; chunks ; types ; pos } in
        if !eod || (!eot && (stuck || tokens = []))
        then state'
        else loop state'
      in
      let state = loop state in
      state, `Bool true
  | _ -> invalid_arguments ()
  end;
}

let command_type = {
  name = "type";

  handler =
  let type_in_env env ppf expr =
    let lexbuf = Lexing.from_string expr in
    let print_expr expression =
      let (str, sg, _) =
        Typemod.type_toplevel_phrase env
          Parsetree.([{ pstr_desc = Pstr_eval expression ; pstr_loc = Location.curr lexbuf }])
      in
      (*let sg' = Typemod.simplify_signature sg in*)
      let open Typedtree in
      begin match str.str_items with
        | [ { str_desc = Tstr_eval exp }] ->
            Printtyp.type_scheme ppf exp.exp_type;
        | _ -> failwith "unhandled expression"
      end
    in
    begin match Chunk_parser.top_expr Lexer.token lexbuf with
      | { Parsetree.pexp_desc = Parsetree.Pexp_construct (longident,None,_) } ->
        begin
          try let _, c = Env.lookup_constructor longident.Asttypes.txt env in
            Browse_misc.print_constructor ppf c
          with Not_found ->
          try let _, m = Env.lookup_module longident.Asttypes.txt env in
           Printtyp.modtype ppf m
          with Not_found ->
          try let p, m = Env.lookup_modtype longident.Asttypes.txt env in
           Printtyp.modtype_declaration (Ident.create (Path.last p)) ppf m
          with Not_found ->
            ()
        end
      | { Parsetree.pexp_desc = Parsetree.Pexp_ident longident } as e ->
        begin
          try print_expr e
          with exn ->
          try let p, t = Env.lookup_type longident.Asttypes.txt env in
           Printtyp.type_declaration (Ident.create (Path.last p)) ppf t
          with _ ->
            raise exn
        end
      | e -> print_expr e
    end
  in
  begin fun _ state -> function
  | [`String "expression"; `String expr] ->
      let env = Typer.env state.types in
      let ppf, to_string = Misc.ppf_to_string () in
      type_in_env env ppf expr;
      state, `String (to_string ())

  | [`String "expression"; `String expr; `String "at" ; jpos] ->
    let {Browse.env} = State.node_at state (Protocol.pos_of_json jpos) in
    let ppf, to_string = Misc.ppf_to_string () in
    type_in_env env ppf expr;
    state, `String (to_string ())

  | [`String "at" ; jpos] ->
    let pos = Protocol.pos_of_json jpos in
    let structures = Misc.list_concat_map
      (fun (str,sg) -> Browse.structure str)
      (Typer.trees state.types)
    in
    let kind, loc = match Browse.nearest_before pos structures with
      | Some { Browse. loc ; context } -> context, loc
      | None -> raise Not_found
    in
    let ppf, to_string = Misc.ppf_to_string () in
    begin match kind with
      | Browse.Other -> raise Not_found
      | Browse.Expr e -> Printtyp.type_scheme ppf e
      | Browse.Type t -> Printtyp.type_declaration (Ident.create "_") ppf t
      | Browse.Module m -> Printtyp.modtype ppf m
      | Browse.Modtype m -> Printtyp.modtype_declaration (Ident.create "_") ppf m
      | Browse.Class (ident, cd) -> Printtyp.class_declaration ident ppf cd
      | Browse.ClassType (ident, ctd) ->
        Printtyp.cltype_declaration ident ppf ctd
    end;
    state, Protocol.with_location loc ["type", `String (to_string ())]

  | [`String "enclosing"; jpos] ->
    let pos = Protocol.pos_of_json jpos in
    let aux = function
      | { Browse. loc ; context = Browse.Expr e } ->
        let ppf, to_string = Misc.ppf_to_string () in
        Printtyp.type_scheme ppf e;
        Some (Protocol.with_location loc ["type", `String (to_string ())])
      | _ -> None
    in
    let structures = Misc.list_concat_map
      (fun (str,sg) -> Browse.structure str)
      (Typer.trees state.types)
    in
    let path = Browse.enclosing pos structures in
    let result = Misc.list_filter_map aux path in
    state, `List [`Int (List.length path); `List result]

  | _ -> invalid_arguments ()
  end;
}

let command_complete = {
  name = "complete";

  handler =
  begin fun _ state -> function
  | [`String "prefix" ; `String prefix] ->
    let node = Browse.({dummy with env = Typer.env state.types}) in
    let compl = State.node_complete node prefix in
    state, `List (List.rev compl)
  | [`String "prefix" ; `String prefix ; `String "at" ; jpos ] ->
    let node = State.node_at state (Protocol.pos_of_json jpos) in
    let compl = State.node_complete node prefix in
    state, `List (List.rev compl)
  | _ -> invalid_arguments ()
  end;
}

let command_seek = {
  name = "seek";

  handler =
  begin fun _ state -> function
  | [`String "position"] ->
    state, Protocol.pos_to_json state.pos

  | [`String "before" ; jpos] ->
    let cmp = 
      let pos = Protocol.pos_of_json jpos in
      fun o -> Misc.compare_pos pos (Outline.item_start o)
    in
    let outlines = state.outlines in
    let outlines = History.seek_forward (fun i -> cmp i > 0) outlines in
    let outlines = History.seek_backward
      (function { Outline.kind = Outline_utils.Syntax_error _loc } -> true
                | i -> cmp i < 0)
      outlines
    in
    let outlines, chunks = History.Sync.rewind fst outlines state.chunks in
    let chunks, types = History.Sync.rewind fst chunks state.types in
    let pos =
      match Outline.location outlines with
        | l when l = Location.none -> State.initial.pos
        | p -> p.Location.loc_end
    in
    { tokens = [] ; outlines ; chunks ; types ; pos },
    Protocol.pos_to_json pos

  | [`String "exact" ; jpos] ->
    let cmp = 
      let pos = Protocol.pos_of_json jpos in
      fun o -> Misc.compare_pos pos (Outline.item_start o)
    in
    let outlines = state.outlines in
    let outlines = History.seek_backward (fun i -> cmp i < 0) outlines in
    let outlines = History.seek_forward (fun i -> cmp i >= 0) outlines in
    let outlines, chunks = History.Sync.rewind fst outlines state.chunks in
    let chunks, types    = History.Sync.rewind fst chunks   state.types  in
    let pos =
      match Outline.location outlines with
      | l when l = Location.none -> State.initial.pos
      | p -> p.Location.loc_end
    in
    { tokens = [] ; outlines ; chunks ; types ; pos },
    Protocol.pos_to_json pos

  | [`String "end"] ->
    let outlines = History.seek_forward (fun _ -> true) state.outlines in
    let chunks = History.Sync.right fst outlines state.chunks in
    let types  = History.Sync.right fst chunks state.types in
    let pos =
      match Outline.location outlines with
      | l when l = Location.none -> State.initial.pos
      | p -> p.Location.loc_end
    in
    { tokens = [] ; outlines ; chunks ; types ; pos },
    Protocol.pos_to_json pos

  | [`String "maximize_scope"] ->
    let rec find_end_of_module (depth,outlines) =
      if depth = 0 then (0,outlines)
      else
      match History.forward outlines with
      | None -> (depth,outlines)
      | Some ({ Outline.kind = Outline_utils.Leave_module },outlines') ->
          find_end_of_module (pred depth, outlines')
      | Some ({ Outline.kind = Outline_utils.Enter_module },outlines') ->
          find_end_of_module (succ depth, outlines')
      | Some (_,outlines') -> find_end_of_module (depth,outlines')
    in
    let rec loop outlines =
      match History.forward outlines with
      | None -> outlines
      | Some ({ Outline.kind = Outline_utils.Leave_module },_) ->
          outlines
      | Some ({ Outline.kind = Outline_utils.Enter_module },outlines') ->
          (match find_end_of_module (1,outlines') with
           | (0,outlines'') -> outlines''
           | _ -> outlines)
      | Some (_,outlines') -> loop outlines'
    in
    let outlines = loop state.outlines in
    let chunks = History.Sync.right fst outlines state.chunks in
    let types  = History.Sync.right fst chunks state.types in
    let pos =
      match Outline.location outlines with
      | l when l = Location.none -> State.initial.pos
      | p -> p.Location.loc_end
    in
    { tokens = [] ; outlines ; chunks ; types ; pos },
    Protocol.pos_to_json pos
  | _ -> invalid_arguments ()
  end;
}

let command_boundary = {
  name = "boundary";

  handler =
  begin fun _ state -> function
  | [] ->
      let boundaries =
        match Outline.location state.outlines with
          | l when l = Location.none -> `Null
          | { Location.loc_start ; Location.loc_end } ->
              `List [
                Protocol.pos_to_json loc_start;
                Protocol.pos_to_json loc_end;
              ]
      in
      state, boundaries
  | _ -> invalid_arguments ()
  end
}

let command_reset = {
  name = "reset";

  handler =
  begin fun _ state -> function
  | [] -> State.initial, Protocol.pos_to_json State.initial.pos
  | [`String "name"; `String pos_fname] ->
    { State.initial with pos =
      { State.initial.pos with Lexing.pos_fname } },
    Protocol.pos_to_json State.initial.pos 
  | _ -> invalid_arguments ()
  end
}

let command_refresh = {
  name = "refresh";

  handler =
  begin fun _ state -> function
  | [] ->
    State.reset_global_modules ();
    Env.reset_cache ();
    let types = Typer.sync state.chunks History.empty in
    {state with types}, `Bool true
  | _ -> invalid_arguments ()
  end;
}

let command_cd = {
  name = "cd";

  handler =
  begin fun _ state -> function
  | [`String s] -> Sys.chdir s; state, `Bool true
  | _ -> invalid_arguments ()
  end;
}

let command_errors = {
  name = "errors";

  handler =
  begin fun _ state -> function
  | [] -> state, `List (Error_report.to_jsons (State.exceptions state))
  | _ -> invalid_arguments ()
  end;
}

let command_dump = {
  name = "dump";

  handler =
  let pr_item_desc items =
    (List.map (fun (s,i) -> `List [`String s;`Int i]) (Chunk.dump_chunk items))
  in
  begin fun _ state -> function
  | [`String "env"] ->
      let sg = Browse_misc.signature_of_env (Typer.env state.types) in
      let aux item =
        let ppf, to_string = Misc.ppf_to_string () in
        Printtyp.signature ppf [item];
        let content = to_string () in
        let ppf, to_string = Misc.ppf_to_string () in
        match Browse_misc.signature_loc item with
          | Some loc ->
              Location.print_loc ppf loc;
              let loc = to_string () in
              `List [`String loc ; `String content]
          | None -> `String content
      in
      state, `List (List.map aux sg)
  | [`String "env" ; `String "at" ; jpos ] ->
    let {Browse.env} = State.node_at state 
        (Protocol.pos_of_json jpos) in
    let sg = Browse_misc.signature_of_env env in
    let aux item =
      let ppf, to_string = Misc.ppf_to_string () in
      Printtyp.signature ppf [item];
      let content = to_string () in
      let ppf, to_string = Misc.ppf_to_string () in
      match Browse_misc.signature_loc item with
        | Some loc ->
            Location.print_loc ppf loc;
            let loc = to_string () in
            `List [`String loc ; `String content]
        | None -> `String content
    in
    state, `List (List.map aux sg)
  | [`String "sig"] ->
      let trees = Typer.trees state.types in
      let sg = List.flatten (List.map snd trees) in
      let aux item =
        let ppf, to_string = Misc.ppf_to_string () in
        Printtyp.signature ppf [item];
        let content = to_string () in
        let ppf, to_string = Misc.ppf_to_string () in
        match Browse_misc.signature_loc item with
          | Some loc ->
              Location.print_loc ppf loc;
              let loc = to_string () in
              `List [`String loc ; `String content]
          | None -> `String content
      in
      state, `List (List.map aux sg)
  | [`String "chunks"] ->
      state, `List (pr_item_desc state.chunks)
  | [`String "tree"] ->
      let structures = Misc.list_concat_map
        (fun (str,sg) -> Browse.structure str)
        (Typer.trees state.types)
      in
      state, Browse_misc.dump_ts structures
  | [`String "outline"] ->
      let outlines = History.prevs state.outlines in
      let aux item =
        let tokens =
          List.map (fun (t,_,_) -> `String (Chunk_parser_utils.token_to_string t))
            item.Outline.tokens
        in
        `List [`String (Outline_utils.kind_to_string item.Outline.kind);
               `List tokens]
      in
      state, `List (List.rev_map aux outlines)
  | _ -> invalid_arguments ()
  end;
}

let command_which = {
  name = "which";

  handler =
  begin fun _ state -> function
  | [`String "path" ; `String s] ->
      let filename =
        try Misc.find_in_path_uncap !State.source_path s
        with Not_found ->
          Misc.find_in_path_uncap !Config.load_path s
      in
      state, `String filename
  | [`String "with_ext" ; `String ext] ->
      let results = Misc.modules_in_path ~ext !State.source_path in
      state, `List (List.map (fun s -> `String s) results)
  | _ -> invalid_arguments ()
  end;
}

let command_find = {
  name = "find";

  handler =
  begin fun _ state -> function
  | [`String "use" ; `List packages]
  | (`String "use" :: packages) ->
      let packages = List.map
        (function `String pkg -> pkg | _ -> invalid_arguments ())
        packages
      in
      let packages = Findlib.package_deep_ancestors [] packages in
      let path = List.map Findlib.package_directory packages in
      Config.load_path := Misc.list_filter_dup (path @ !Config.load_path);
      State.reset_global_modules ();
      state, `Bool true
  | [`String "list"] ->
      state, `List (List.rev_map (fun s -> `String s) (Fl_package_base.list_packages ()))
  | _ -> invalid_arguments ()
  end;
}

let command_help = {
  name = "help";

  handler =
  begin fun _ state -> function
  | [] ->
      let helps = Hashtbl.fold
        (fun name _ cmds -> `String name :: cmds)
        commands []
      in
      state, `List helps
  | _ -> invalid_arguments ()
  end;
}

let _ = List.iter register [
  command_tell; command_seek; command_reset; command_refresh;
  command_cd; command_type; command_complete; command_boundary;
  command_errors; command_dump;
  command_which; command_find;
  command_help;
]
