(* Yoann Padioleau
 *
 * Copyright (C) 2009, 2010 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

open Common

module J = Json_type

module HC = Highlight_code

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*
 * This module provides a generic "database" of semantic information on a 
 * codebase (a la CIA [1]). The goal is to give access to information computed
 * by a set of global static or dynamic analysis such as what are the
 * number of callers to a certain function, what is the test coverage of
 * a file, etc.
 * 
 * Each programming language analysis library usually provide
 * a more powerful database (e.g. analyze_php/database/database_php.mli)
 * with more information. Such a database is usually also efficiently stored
 * on disk via BerkeleyDb. Nevertheless generic tools like the
 * code visualizer can benefit from a shorter and generic version of this
 * database. Moreover when we have codebase with multiple langages
 * (e.g. PHP and javascript), having a common type can help for some
 * analysis or visualization.
 * 
 * Note that by storing this toy database in a JSON format or with Marshall,
 * this database can also easily be read by multiple
 * process at the same time (there is currently a few problems with
 * concurrent access of Berkeley Db data; for instance one database
 * created by a user can not even be read by another user ...).
 * This also avoid forcing the user to spend time running all
 * the global analysis on his own codebase. We can factorize the essential
 * results of such long computation in a single file.
 * 
 * An alternative would be to use the TAGS file or information from
 * cscope. But this would require to implement a reader for those
 * two formats. Moreover ctags/cscope do just lexical-based analysis
 * so it's not a good basis and it contains only defition->position
 * information.
 * 
 * 
 * history: 
 *  - started when working for eurosys'06 in patchparse/ in a file called
 *    c_info.ml
 *  - extended for eurosys'08 for coccinelle/ in coccinelle/extra/ 
 *    and use it to discover some .c .h mapping and generate some crazy 
 *    graphs and also to detect drivers splitted in multiple files.
 *  - extended it for aComment in 2008 and 2009, to feed information to some 
 *    inter-procedural analysis.
 *  - rewrite it for PHP in Nov 2009
 *  - adapted in Jan 2010 for flib_navigator
 *  - make it generic in Aug 2010 for my code/treemap visualizer
 * 
 * history bis:
 *  - Before, I was optimizing stuff by caching the ast in 
 *    some xxx_raw files. But there was lots of small raw files; 
 *    get lots of ast files and waste space. Also not good for random
 *    access to the asts. So better to use berkeley DB. My experience with
 *    LFS helped me a little as I was already using berkeley DB and glimpse.
 *    
 *  - I was also using glimpse and I tried to accelerate even more coccinelle
 *    to generate some mini C files so that glimpse can directly tell us
 *    the toplevel elements to look for. But this generates lots of 
 *    very small mini C files which also waste lots of disk space.
 * 
 * References:
 *  [1] CIA, the C Information Abstractor
 *)

(*****************************************************************************)
(* Type *)
(*****************************************************************************)

(* Yet another entity type. Could perhaps factorize code with
 * highlight_code.ml.
 * If you add a constructor don't forget to modify entity_kind_of_string
 *)
type entity_kind = 
  | Function
  | Class
  | Module
  | Type
  | Constant
  | Global
  | Macro

  (* nested entities *)
  | Method
  | StaticMethod
  | Field

  (* when we use the database for completion purpose, then files/dirs
   * are also useful "entities" to get completion for.
   *)
  | File
  | Dir
  (* people often spread the same component in multiple dirs with the same
   * name
   *)
  | MultiDirs

(* How to store the id of an entity ? A int ? A name and hope few conflicts ?
 * Using names will increase the size of the db which will slow down
 * the loading of the database.
 * 
 * So it's better to use an id. Moreover at some point we want to provide
 * callers/callees navigations and more entities relationships
 * so we need a real way to reference an entity.
 *)

type entity_id = int


type entity = {
  e_kind: entity_kind;

  e_name: string;
  (* can be empty to save space when e_fullname = e_name *)
  e_fullname: string;

  e_file: Common.filename;
  e_pos: Common.filepos;
  
  (* Semantic information that can be leverage by a code visualizer.
   * The fields are set as mutable because usually we compute
   * the set of all entities in a first phase and then we
   * do another pass where we adjust numbers of other entity references.
   *)
  
  (* todo: could give more importance when used externally not just from
   * another file but from another directory!
   * or could refine this int with more information.
   *)
  mutable e_number_external_users: int;

  (* Usually the id of a unit test of pleac file. 
   *
   * Indeed a simple algorithm to compute this list is:
   * just look at the callers, filter the one in unit test or pleac files, 
   * then for each caller, look at the number of callees, and take
   * the one with best ratio.
   * 
   * With references to good examples of use, we can offer
   * what Perl programmers had for years with their function 
   * documentations.
   * If there is no examples_of_use then the user can visually
   * see that some functions should be unit tested :)
   *)
  mutable e_good_examples_of_use: entity_id list;

  (* todo? code_rank ? this is more useful for number_internal_users
   * when we want to know what is the core function in a module,
  * even when it's called only once, but by a small wrapper that is
  * itself very often called.
  *)
 }


(* Note that because we now use indexed entities, you can not
 * play with.entities as before. For instance merging databases
 * requires to adjust all the entity_id internal references.
 *)
type database = {

  (* The common root if the database was built with multiple dirs
   * as an argument. Such a root is mostly useful when displaying
   * filenames in which case we can strip the root from it
   * (e.g. in the treemap browser when we mouse over a rectangle).
   *)
  root: Common.dirname;

  (* Such list can be used in a search box powered by completion.
   * The int is for the total number of times this files is
   * externally referenced. Can be use for instance in the treemap
   * to artificially augment the size of what is probably a more 
   * "important" file.
  *)
  dirs: (Common.filename * int) list;

  (* see also build_top_k_sorted_entities_per_file for dynamically
   * computed summary information for a file 
   *)
  files: (Common.filename * int) list;

  (* indexed by entity_id *)
  entities: entity array;
  (* TODO: leverage git information *)
  (* TODO: leverage dynamic information *)
  (* TODO: leverage owners information *)
  (* TODO: leverage test information *)
}

let empty_database () = {
  root = "";
  dirs = [];
  files = [];
  entities = Array.of_list [];
}

let default_db_name = 
  "PFFF_DB.db"
(*****************************************************************************)
(* String of *)
(*****************************************************************************)

(* todo: should be autogenerated !! *)
let string_of_entity_kind e = 
  match e with
  | Function -> "Function"
  | Class -> "Class"
  | Module -> "Module"
  | Type -> "Type"
  | Constant -> "Constant"
  | Global -> "Global"
  | Macro -> "Macro"
  | Method -> "Method"
  | StaticMethod -> "StaticMethod"
  | Field -> "Field"
  | File -> "File"
  | Dir -> "Dir"
  | MultiDirs -> "MultiDirs"

let entity_kind_of_string s =
  match s with
  | "Function" -> Function
  | "Class" -> Class
  | "Module" -> Module
  | "Type" -> Type
  | "Constant" -> Constant
  | "Global" -> Global
  | "Macro" -> Macro
  | "Method" -> Method
  | "StaticMethod" -> StaticMethod
  | "Field" -> Field
  | "File" -> File
  | "Dir" -> Dir
  | "MultiDirs" -> MultiDirs
  | _ -> failwith ("entity_of_string: bad string = " ^ s)

(*****************************************************************************)
(* Json *)
(*****************************************************************************)

(*---------------------------------------------------------------------------*)
(* json -> X *)
(*---------------------------------------------------------------------------*)

let ids_of_json json = 
  match json with
  | J.Array xs ->
      xs +> List.map (function
      | J.Int id -> id
      | _ -> failwith "bad json"
      )
  | _ -> failwith "bad json"


let int_of_entity_kind e = 
  match e with
  | Function -> 1
  | Class -> 2
  | Module -> 3
  | Type -> 4
  | Constant -> 5
  | Global -> 6
  | Method -> 7
  | StaticMethod -> 8
  | Field -> 9
  | File -> 10
  | Dir -> 11
  | MultiDirs -> 12
  | Macro -> 13

let entity_kind_of_int i = 
  match i with
  | 1 -> Function
  | 2 -> Class
  | 3 -> Module
  | 4 -> Type
  | 5 -> Constant
  | 6 -> Global
  | 7 -> Method
  | 8 -> StaticMethod
  | 9 -> Field
  | 10 -> File
  | 11 -> Dir
  | 12 -> MultiDirs
  | 13 -> Macro
  | _ -> failwith "wrong entity number"


let string_short_of_entity_kind e = 
  match e with
  | Function -> "F"
  | Class -> "Cl"
  | Module -> "Mo"
  | Type -> "T"
  | Constant -> "Co"
  | Global -> "G"
  | Macro -> "Mc"
  | Method -> "Me"
  | StaticMethod -> "SM"
  | Field -> "Fld"
  | File -> "Fi"
  | Dir -> "Di"
  | MultiDirs -> "Md"


let json_of_filepos x = 
  J.Array [J.Int x.Common.l; J.Int x.Common.c]

let json_of_entity e = 
  J.Object [
    "k", J.String (string_of_entity_kind e.e_kind);
    "n", J.String e.e_name;
    "fn", J.String e.e_fullname;
    "f", J.String e.e_file;
    "p", json_of_filepos e.e_pos;
    (* different from type *)
    "cnt", J.Int e.e_number_external_users;
    "u", J.Array (e.e_good_examples_of_use +> List.map (fun id -> J.Int id));
  ]

let json_compact_of_entity e =
  J.Array [
    J.Int (int_of_entity_kind e.e_kind);
    J.String e.e_name;
    J.String e.e_fullname;
    J.String e.e_file;
    J.Int e.e_pos.Common.l;
    J.Int e.e_pos.Common.c;
    J.Int e.e_number_external_users;
    J.Array (e.e_good_examples_of_use +> List.map (fun id -> J.Int id));
  ]

let json_of_database db = 
  J.Object [
    "root", J.String db.root;
    "dirs", J.Array (db.dirs +> List.map (fun (x, i) ->
      J.Array([J.String x; J.Int i])));
    "files", J.Array (db.files +> List.map (fun (x, i) ->
      J.Array([J.String x; J.Int i])));
    "entities", J.Array (db.entities +> 
                         Array.to_list +> List.map json_compact_of_entity);
  ]

(*---------------------------------------------------------------------------*)
(* X -> json *)
(*---------------------------------------------------------------------------*)

let filepos_of_json json = 
  match json with
  | J.Array [J.Int l; J.Int c] ->
      { Common.l = l; Common.c = c }
  | _ -> failwith "Bad json"

(* Reverse of json_of_entity_info; must follow same convention for the order
 * of the fields.
 *)
let entity_of_json2 json =
  match json with
  | J.Object [
    "k", J.String e_kind;
    "n", J.String e_name;
    "fn", J.String e_fullname;
    "f", J.String e_file;
    "p", e_pos;
    (* different from type *)
    "cnt", J.Int e_number_external_users;
    "u", ids;
    ] -> {
      e_kind = entity_kind_of_string e_kind;
      e_name = e_name;
      e_file = e_file;
      e_fullname = e_fullname;
      e_pos = filepos_of_json e_pos;
      e_number_external_users = e_number_external_users;
      e_good_examples_of_use = ids_of_json ids;
      
    }
  | _ -> failwith "Bad json"

let entity_of_json a = 
  Common.profile_code "Db.entity_of_json" (fun () ->
    entity_of_json2 a)

let entity_of_json_compact json =
  match json with
  | J.Array [
      J.Int e_kind;
      J.String e_name;
      J.String e_fullname;
      J.String e_file;
      J.Int e_pos_l; 
      J.Int e_pos_c;
      J.Int e_number_external_users;
      ids;
    ] -> {
      e_kind = entity_kind_of_int e_kind;
      e_name = e_name;
      e_file = e_file;
      e_fullname = e_fullname;
      e_pos = { Common.l = e_pos_l; Common.c = e_pos_c };
      e_number_external_users = e_number_external_users;
      e_good_examples_of_use = ids_of_json ids
  }
  | _ -> failwith "Bad json"


let database_of_json2 json =
  match json with
  | J.Object [
    "root", J.String db_root;
    "dirs", J.Array db_dirs;
    "files", J.Array db_files;
    "entities", J.Array db_entities;
    ] -> {
      root = db_root;
      
      dirs = db_dirs +> List.map (fun json ->
        match json with
        | J.Array([J.String x; J.Int i]) ->
            x, i
        | _ -> failwith "Bad json"
      );

      files = db_files +> List.map (fun json ->
        match json with
        | J.Array([J.String x; J.Int i]) ->
            x, i
        | _ -> failwith "Bad json"
      );
      entities = 
        db_entities +> List.map entity_of_json_compact +> Array.of_list
    }
      
  | _ -> failwith "Bad json"

let database_of_json json =
  Common.profile_code "Db.database_of_json" (fun () -> 
    database_of_json2 json
  )

(*****************************************************************************)
(* Load/Save *)
(*****************************************************************************)

(* could use JSON or Marshall *)
let load_database2 file =
  let json = 
    Common.profile_code2 "Json_in.load_json" (fun () ->
      Json_in.load_json file
    ) in
  let db = database_of_json json in
  db
let load_database file =
  Common.profile_code2 "Db.load_db" (fun () -> load_database2 file)


(* todo? use the more efficient json pretty printer ? *)
let save_database ?(readable_db=false) database file =
   database |> json_of_database |> 
       Json_io.string_of_json ~compact:(not readable_db) ~recursive:false
   |> Common.write_file ~file


(*****************************************************************************)
(* Entities categories *)
(*****************************************************************************)


let entity_kind_of_highlight_category_def categ = 
  (* TODO: constant *)
  match categ with
  | HC.Function (HC.Def2 _) -> Function
  | HC.FunctionDecl _ -> Function
  | HC.Global (HC.Def2 _) -> Global
  | HC.Class (HC.Def2 _) -> Class
  | HC.Method (HC.Def2 _) -> Method
  | HC.Field (HC.Def2 _) -> Field
  | HC.StaticMethod (HC.Def2 _) -> StaticMethod
  | HC.Macro (HC.Def2 _) -> Macro (* todo? want agglomerate ? *)
  | HC.MacroVar (HC.Def2 _) -> Macro

  | HC.Module HC.Def -> Module
  | HC.TypeDef HC.Def -> Type
  | _ -> 
      failwith "this category has no Database_code counterpart"

let entity_kind_of_highlight_category_use categ = 
  (* TODO: constant *)
  match categ with
  | HC.Function (HC.Use2 _) -> Function
  | HC.FunctionDecl _ -> Function
  | HC.Global (HC.Use2 _) -> Global
  | HC.Class (HC.Use2 _) -> Class
  | HC.Method (HC.Use2 _) -> Method
  | HC.Field (HC.Use2 _) -> Field
  | HC.StaticMethod (HC.Use2 _) -> StaticMethod
  | HC.Macro (HC.Use2 _) -> Macro (* todo? want agglomerate ? *)
  | HC.MacroVar (HC.Use2 _) -> Macro

  | HC.Module HC.Use -> Module
  | HC.TypeDef HC.Use -> Type

  | HC.StructName HC.Use -> Class
  | _ -> 
      failwith "this category has no Database_code counterpart"


(* In database_light_xxx we sometimes need given a use to increment
 * the e_number_external_users counter of an entity. Nevertheless
 * multiple entities may have the same name in which case looking
 * for an entity in the environment will return multiple
 * entities of different kinds. Here we filter back the
 * non valid entities.
 *)
let entity_and_highlight_category_correpondance entity categ =
  let entity_kind_use = entity_kind_of_highlight_category_use categ in
  entity.e_kind = entity_kind_use


(*****************************************************************************)
(* Misc *)
(*****************************************************************************)

(* When we compute the light database for a language we usually start
 * by calling a function to get the set of files in this language
 * (e.g. Lib_parsing_ml.find_all_ml_files) and then "infer"
 * the set of directories used by those files by just calling dirname
 * on them. Nevertheless in the search box of the visualizer we
 * want to propose for instance flib/herald even if there is no
 * php file in flib/herald but files in flib/herald/lib/foo.php.
 * Having flib/herald/lib is not enough. Enter alldirs_and_parent_dirs_of_dirs
 * which will compute all the directories.
 * 
 * It's a kind of 'find -type d' but reversed, using a set of complete dirs
 * as the starting point. In fact we could define a 
 * Common.dirs_of_dirs but then directory without any interesting files
 * would be listed.
 *)
let alldirs_and_parent_dirs_of_relative_dirs dirs =
  dirs 
  +> List.map Common.inits_of_relative_dir 
  +> List.flatten +> Common.uniq_eff



let merge_databases db1 db2 =
  (* assert same root ?
   * then can just additionner the fields
   *)
  if db1.root <> db2.root
  then begin
    pr2 (spf "merge_database: the root differs, %s != %s"
            db1.root db2.root);
    if not (Common.y_or_no "Continue ?")
    then failwith "ok we stop";
  end;

  (* entities now contain references to other entities through
   * the index to the entities array. So concatenating 2 array
   * entities requires care.
   *)
  let length_entities1 = Array.length db1.entities in
  
  let db2_entities = db2.entities in
  let db2_entities_adjusted = 
    db2_entities +> Array.map (fun e ->
      { e with
        e_good_examples_of_use = 
          e.e_good_examples_of_use 
          +> List.map (fun id -> id + length_entities1);
      }
    )
  in

  {
    root = db1.root;
    dirs = (db1.dirs ++ db2.dirs) 
      +> Common.group_assoc_bykey_eff
      +> List.map (fun (file, xs) ->
        file, Common.sum xs
      );
    files = db1.files ++ db2.files; (* should ensure exclusive ? *)
    entities = Array.append db1.entities db2_entities_adjusted;
  }


let build_top_k_sorted_entities_per_file2 ~k xs =
  xs 
  +> Array.to_list
  +> List.map (fun e -> e.e_file, e)
  +> Common.group_assoc_bykey_eff
  +> List.map (fun (file, xs) ->
    file, (xs +> List.sort (fun e1 e2 ->
      (* high first *)
      compare e2.e_number_external_users e1.e_number_external_users
    ) +> Common.take_safe k
    )
  ) +> Common.hash_of_list

let build_top_k_sorted_entities_per_file ~k xs =
  Common.profile_code2 "Db.build_sorted_entities" (fun () ->
    build_top_k_sorted_entities_per_file2 ~k xs
  )


let mk_dir_entity dir n = { 
  e_name = Common.basename dir ^ "/";
  e_fullname = "";
  e_file = dir;
  e_pos = { Common.l = 1; Common.c = 0 };
  e_kind = Dir;
  e_number_external_users = n;
  e_good_examples_of_use = [];
}
let mk_file_entity file n = { 
  e_name = Common.basename file;
  e_fullname = "";
  e_file = file;
  e_pos = { Common.l = 1; Common.c = 0 };
  e_kind = File;
  e_number_external_users = n;
  e_good_examples_of_use = [];
}

let mk_multi_dirs_entity name dirs_entities =
  let dirs_fullnames = dirs_entities +> List.map (fun e -> e.e_file) in

  {
  e_name = name ^ "//";
  (* hack *)
  e_fullname = "";

  (* hack *)
  e_file = Common.join "|" dirs_fullnames;

  e_pos = { Common.l = 1; Common.c = 0 };
  e_kind = MultiDirs;
  e_number_external_users = 
    (* todo? *)
    (List.length dirs_fullnames);
  e_good_examples_of_use = [];
  }

let multi_dirs_entities_of_dirs es =
  let h = Hashtbl.create 101 in
  es +> List.iter (fun e ->
    Hashtbl.add h e.e_name e
  );
  let keys = Common.hkeys h in
  keys +> Common.map_filter (fun k ->
    let vs = Hashtbl.find_all h k in
    if List.length vs > 1
    then Some (mk_multi_dirs_entity k vs)
    else None
  )

let files_and_dirs_and_sorted_entities_for_completion2
 ~threshold_too_many_entities
 db 
 =
  let nb_entities = Array.length db.entities in

  let dirs = 
    db.dirs +> List.map (fun (dir, n) -> mk_dir_entity dir n)
  in
  let files = 
    db.files +> List.map (fun (file, n) -> mk_file_entity file n)
  in
  let multidirs = multi_dirs_entities_of_dirs dirs in

  let xs =
   multidirs ++ dirs ++ files ++
   (if nb_entities > threshold_too_many_entities
    then begin 
      pr2 "Too many entities. Completion just for filenames";
      []
    end else 
       (db.entities +> Array.to_list +> List.map (fun e -> 
         (* we used to return 2 entities per entity by having
          * both an entity with the short name and one with the long
          * name, but now that we do a suffix search, no need
          * to keep the short one
          *)
         if e.e_fullname = "" 
         then e
         else { e with e_name = e.e_fullname }
       )
       )
   )
  in

  (* note: return first the dirs and files so that when offer
   * completion the dirs and files will be proposed first
   * (could also enforce this rule when building the gtk completion model).
   *)
  xs +> List.map (fun e ->
    (match e.e_kind with
    | MultiDirs -> 100
    | Dir -> 40
    | File -> 20
    | _ -> e.e_number_external_users
    ), e
  ) +> Common.sort_by_key_highfirst
  +> List.map snd

  
let files_and_dirs_and_sorted_entities_for_completion
    ~threshold_too_many_entities a =
 Common.profile_code2 "Db.sorted_entities" (fun () ->
   files_and_dirs_and_sorted_entities_for_completion2
    ~threshold_too_many_entities a)



(* The e_number_external_users count is not always very accurate for methods
 * when we do very trivial class/methods analysis for some languages.
 * This helper function can compensate back this approximation.
 *)

let adjust_method_or_field_external_users entities =
  (* phase1: collect all method counts *)
  let h_method_def_count = Common.hash_with_default (fun () -> 0) in
  
  entities +> Array.iter (fun e ->
    match e.e_kind with
    (* do also for staticMethods ? hmm should be less needed *)
    | Method | Field ->
        let k = e.e_name in
        h_method_def_count#update k (Common.add1)
    | _ -> ()
  );

  (* phase2: adjust *)
  entities +> Array.iter (fun e ->
    match e.e_kind with
    | Method | Field ->
        let k = e.e_name in
        let nb_defs = h_method_def_count#assoc k in
        if nb_defs > 1
        then pr2 ("Adjusting: " ^ e.e_fullname);

        let orig_number = e.e_number_external_users in
        e.e_number_external_users <- orig_number / nb_defs;
    | _ -> ()
  );
  ()
