open Camlp4.PreCast ;;
open Syntax ;;
open Camlp4_to_ppx ;;

let linkme = () ;;

(* lots of stuff copied from Eliom pa_eliom_seed.ml *)

let merge_locs l ls = List.fold_left Token.Loc.merge ls l ;;

let rec filter =
  (* parser keyword in next line for less horrendous auto-indent *)
  parser

| [< '(KEYWORD "{", loc0); next >] ->
  (match next with
     parser
   | [< '(KEYWORD "{", loc1); nnext >] -> (* {{ *)
     [< '(KEYWORD "{{", merge_locs [loc1] loc0); filter nnext >]
   | [< '(LIDENT "shared", loc1); nnnext >] ->
     (match nnnext with
        parser
      | [< '(KEYWORD "#", loc2); nnnnext >] -> (* {shared# *)
        [< '(KEYWORD ("{shared#"), merge_locs [loc1; loc2] loc0);
           filter nnnnext
        >]
      | [< '(KEYWORD "{", loc2); nnnnext >] -> (* {shared{ *)
        [< '(KEYWORD ("{shared{"), merge_locs [loc1; loc2] loc0);
           filter nnnnext
        >]
      | [< 'other; nnnnext >] -> (* back *)
        [< '(KEYWORD "{", loc0); '(LIDENT "shared", loc1); 'other;
           filter nnnnext
        >])
   | [< '(LIDENT ("client"|"server" as s), loc1); nnnext >] ->
     (match nnnext with
        parser
      | [< '(KEYWORD "{", loc2); nnnnext >] -> (* {smthg{ *)
        [< '(KEYWORD ("{"^s^"{"), merge_locs [loc1; loc2] loc0);
           filter nnnnext
        >]
      | [< 'other; nnnnext >] -> (* back *)
        [< '(KEYWORD "{", loc0); '(LIDENT s, loc1); 'other;
           filter nnnnext
        >])
   | [< 'other; nnext >] -> (* back *)
     [< '(KEYWORD "{", loc0); 'other; filter nnext >])

| [< '(KEYWORD "}", loc0); next >] ->
  (match next with
     parser
   | [< '(KEYWORD "}", loc1); nnext >] ->
     [< '(KEYWORD "}}", merge_locs [loc1] loc0); filter nnext >]
   | [< 'other; nnext >] -> (* back *)
     [< '(KEYWORD "}", loc0); 'other; filter nnext >])

| [< 'other; next >] ->
  let is_left_delimitor str = List.mem str.[0] ['('; '['; '{'] in
  let ends_with_percent_sign str = str.[String.length str-1] = '%' in
  match other with
  | (* Allow %-sign to for injection directly after left delimitors *)
    SYMBOL str, loc0 when String.length str > 0 &&
                          is_left_delimitor str &&
                          ends_with_percent_sign str ->
    let left = String.sub str 0 (String.length str - 1) in
    let loc_left = Loc.move `stop (-1) loc0 in
    let loc_right = Loc.move `start (String.length str - 1) loc0 in
    [< '(KEYWORD left, loc_left);
       '(SYMBOL "%", loc_right);
       filter next >]
  | _ ->
    [< 'other; filter next >] ;;

let () =
  Token.Filter.define_filter
    (Gram.get_filter ())
    (fun old_filter stream -> old_filter (filter stream)) ;;

type section = S_Server | S_Shared | S_Client ;;

let get_section, set_section =
  let current = ref S_Server in
  (fun () -> !current),
  (fun s -> current := s) ;;

(* no error checking ; pa_eliom_* && ppx_eliom_* can do that *)

DELETE_RULE Gram expr: "{"; TRY [label_expr_list; "}"] END ;;

DELETE_RULE Gram expr:
  "{"; TRY [expr LEVEL "."; "with"]; label_expr_list; "}" END ;;

EXTEND Gram GLOBAL: str_item expr;

set_section_server:
  [[ -> set_section S_Server ]];

set_section_shared:
  [[ -> set_section S_Shared ]];

set_section_client:
  [[ -> set_section S_Client ]];

located_begin_brackets: [[ KEYWORD "{{" -> _loc ]];

located_end_brackets: [[ KEYWORD "}}" -> _loc ]];

located_shared_y: [[
    KEYWORD "{shared#";
    y = OPT ctyp;
    KEYWORD "{" -> y, _loc
  ]];

located_client_y: [[
    KEYWORD "{";
    y = OPT ctyp;
    KEYWORD "{" -> y, _loc
  ]];

str_item:
  BEFORE "top" [
    "eliom"
      [ loc = [ KEYWORD "{server{" -> _loc ];
        _ = set_section_server; _ = LIST0 str_item ;
        loc' = located_end_brackets ->
        replace loc "[%%server ]";
        replace loc' "";
        <:str_item<>>
      | loc = [ KEYWORD "{shared{" -> _loc ];
        _ = set_section_server; _ = LIST0 str_item ;
        loc' = located_end_brackets ->
        replace loc "[%%shared ]";
        replace loc' "[%%server ]";
        <:str_item<>>
      | loc = [ KEYWORD "{client{" -> _loc ];
        _ = set_section_server; _ = LIST0 str_item ;
        loc' = located_end_brackets ->
        replace loc "[%%client ]";
        replace loc' "[%%server ]";
        <:str_item<>>
      ]
  ];

expr:
  LEVEL "simple" [
    [ KEYWORD "{"; _ = TRY [_ = label_expr_list; "}"] ->
      <:expr<>>
    | (y, loc) = located_shared_y; expr;
      loc' = located_end_brackets ->
      replace loc "[%se ";
      replace loc' "]";
      <:expr<>>
    | KEYWORD "{"; loc = TRY [OPT ctyp; KEYWORD "{"];
      e = expr;
      loc' = located_end_brackets ->
      <:expr<>>
    | KEYWORD "{"; expr LEVEL "."; "with"; label_expr_list; "}" ->
      <:expr<>>
    | loc = located_begin_brackets;
      e = expr;
      loc' = located_end_brackets ->
      replace loc " [%ce ";
      replace loc' "]";
      <:expr<>>
    ]
  ];

located_percent: [[ SYMBOL "%" -> _loc ]];

expr:
  BEFORE "simple" [
    [ loc = located_percent; KEYWORD "("; e = expr; KEYWORD ")" ->
      replace loc "~%"; <:expr<>>
    | loc = located_percent; id = ident ->
      replace loc "~%"; <:expr<>>
    ]
  ];

END
