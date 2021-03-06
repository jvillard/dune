open Import
open Stanza.Of_sexp

(* This file defines the jbuild types as well as the S-expression
   syntax for the various supported version of the specification.
*)

(* Deprecated *)
module Jbuild_version = struct
  type t =
    | V1

  let t =
    enum
      [ "1", V1
      ]
end

let invalid_module_name ~loc =
  of_sexp_errorf loc "invalid module name: %S"

let module_name =
  plain_string (fun ~loc name ->
    match name with
    | "" -> invalid_module_name ~loc name
    | s ->
      try
        (match s.[0] with
         | 'A'..'Z' | 'a'..'z' -> ()
         | _ -> raise_notrace Exit);
        String.iter s ~f:(function
          | 'A'..'Z' | 'a'..'z' | '0'..'9' | '\'' | '_' -> ()
          | _ -> raise_notrace Exit);
        String.capitalize s
      with Exit ->
        invalid_module_name ~loc name)

let module_names = list module_name >>| String.Set.of_list

let invalid_lib_name ~loc = of_sexp_errorf loc "invalid library name"

let library_name =
  plain_string (fun ~loc name ->
    match name with
    | "" -> invalid_lib_name ~loc
    | s ->
      if s.[0] = '.' then invalid_lib_name ~loc
      else
        try
          String.iter s ~f:(function
            | 'A'..'Z' | 'a'..'z' | '_' | '.' | '0'..'9' -> ()
            | _ -> raise_notrace Exit);
          s
        with Exit -> invalid_lib_name ~loc)

let file =
  plain_string (fun ~loc s ->
    match s with
    | "." | ".." ->
      of_sexp_errorf loc "'.' and '..' are not valid filenames"
    | fn -> fn)

let file_in_current_dir =
  plain_string (fun ~loc s ->
    match s with
    | "." | ".." ->
      of_sexp_errorf loc "'.' and '..' are not valid filenames"
    | fn ->
      if Filename.dirname fn <> Filename.current_dir_name then
        of_sexp_errorf loc "file in current directory expected"
      else
        fn)

let relative_file =
  plain_string (fun ~loc fn ->
    if Filename.is_relative fn then
      fn
    else
      of_sexp_errorf loc "relative filename expected")

let c_name, cxx_name =
  let make what ext =
    plain_string (fun ~loc s ->
      if match s with
        | "" | "." | ".."  -> true
        | _ -> Filename.basename s <> s then
        of_sexp_errorf loc
          "%S is not a valid %s name.\n\
           Hint: To use %s files from another directory, use a \
           (copy_files <dir>/*.%s) stanza instead."
          s what what ext
      else
        s)
  in
  (make "C"   "c",
   make "C++" "cpp")

(* Parse and resolve "package" fields *)
module Pkg = struct
  let listing packages =
    let longest_pkg =
      String.longest_map packages ~f:(fun p ->
        Package.Name.to_string p.Package.name)
    in
    String.concat ~sep:"\n"
      (List.map packages ~f:(fun pkg ->
         sprintf "- %-*s (because of %s)" longest_pkg
           (Package.Name.to_string pkg.Package.name)
           (Path.to_string (Package.opam_file pkg))))

  let default (project : Dune_project.t) =
    match Package.Name.Map.values project.packages with
    | [pkg] -> Ok pkg
    | [] ->
      Error
        "The current project defines some public elements, \
         but no opam packages are defined.\n\
         Please add a <package>.opam file at the project root \
         so that these elements are installed into it."
    | _ :: _ :: _ ->
      Error
        (sprintf
           "I can't determine automatically which package this (install ...) \
            stanza is for. I have the choice between these ones:\n\
            %s\n\
            You need to add a (package ...) field in this (install ...) stanza"
           (listing (Package.Name.Map.values project.packages)))

  let resolve (project : Dune_project.t) name =
    match Package.Name.Map.find project.packages name with
    | Some pkg ->
      Ok pkg
    | None ->
      let name_s = Package.Name.to_string name in
      if Package.Name.Map.is_empty project.packages then
        Error (sprintf
                 "You cannot declare items to be installed without \
                  adding a <package>.opam file at the root of your project.\n\
                  To declare elements to be installed as part of package %S, \
                  add a %S file at the root of your project."
                 name_s (Package.Name.opam_fn name))
      else
        Error (sprintf
                 "The current scope doesn't define package %S.\n\
                  The only packages for which you can declare \
                  elements to be installed in this directory are:\n\
                  %s%s"
                 name_s
                 (listing (Package.Name.Map.values project.packages))
                 (hint name_s (Package.Name.Map.keys project.packages
                               |> List.map ~f:Package.Name.to_string)))

  let t =
    let%map p = Dune_project.get_exn ()
    and (loc, name) = located Package.Name.t in
    match resolve p name with
    | Ok    x -> x
    | Error e -> Loc.fail loc "%s" e

  let field =
    map_validate
      (let%map p = Dune_project.get_exn ()
       and pkg = field_o "package" string in
       (p, pkg))
      ~f:(fun (p, pkg) ->
        match pkg with
        | None -> default p
        | Some name -> resolve p (Package.Name.of_string name))
end

module Pp : sig
  type t = private string
  val of_string : string -> t
  val to_string : t -> string
  val compare : t -> t -> Ordering.t
end = struct
  type t = string

  let of_string s =
    assert (not (String.is_prefix s ~prefix:"-"));
    s

  let to_string t = t

  let compare = String.compare
end

module Pps_and_flags = struct
  module Jbuild_syntax = struct
    let of_string ~loc s =
      if String.is_prefix s ~prefix:"-" then
        Right [s]
      else
        Left (loc, Pp.of_string s)

    let item =
      peek_exn >>= function
      | Template { loc; _ } ->
        no_templates loc "in the preprocessors field"
      | Atom _ | Quoted_string _ -> plain_string of_string
      | List _ -> list string >>| fun l -> Right l

    let split l =
      let pps, flags =
        List.partition_map l ~f:(fun x -> x)
      in
      (pps, List.concat flags)

    let t = list item >>| split
  end

  module Dune_syntax = struct
    let t =
      let%map l, flags =
        until_keyword "--"
          ~before:(plain_string (fun ~loc s -> (loc, s)))
          ~after:(repeat string)
      in
      let pps, more_flags =
        List.partition_map l ~f:(fun (loc, s) ->
          if String.is_prefix s ~prefix:"-" then
            Right s
          else
            Left (loc, Pp.of_string s))
      in
      (pps, more_flags @ Option.value flags ~default:[])
  end

  let t =
    Syntax.get_exn Stanza.syntax >>= fun ver ->
    if ver < (1, 0) then
      Jbuild_syntax.t
    else
      Dune_syntax.t
end

module Bindings = struct
  type 'a one =
    | Unnamed of 'a
    | Named of string * 'a list

  type 'a t = 'a one list

  let fold t ~f ~init = List.fold_left ~f:(fun acc x -> f x acc) ~init t

  let to_list =
    List.concat_map ~f:(function
      | Unnamed x -> [x]
      | Named (_, xs) -> xs)

  let find t k =
    List.find_map t ~f:(function
      | Unnamed _ -> None
      | Named (k', x) -> Option.some_if (k = k') x)

  let empty = []

  let singleton x = [Unnamed x]

  let t elem =
    Stanza.file_kind () >>= function
    | Jbuild -> list (elem >>| fun x -> Unnamed x)
    | Dune -> parens_removed_in_dune (
      let%map l =
        repeat
          (if_paren_colon_form
             ~then_:(
               let%map values = repeat elem in
               fun (loc, name) ->
                 Left (loc, name, values))
             ~else_:(elem >>| fun x -> Right x))
      in
      let rec loop vars acc = function
        | [] -> List.rev acc
        | Right x :: l -> loop vars (Unnamed x :: acc) l
        | Left (loc, name, values) :: l ->
          let vars =
            if not (String.Set.mem vars name) then
              String.Set.add vars name
            else
              of_sexp_errorf loc "Variable %s is defined for the second time."
                name
          in
          loop vars (Named (name, values) :: acc) l
      in
      loop String.Set.empty [] l)

  let sexp_of_t sexp_of_a bindings =
    Sexp.List (
      List.map bindings ~f:(function
        | Unnamed a -> sexp_of_a a
        | Named (name, bindings) ->
          Sexp.List (Sexp.atom (":" ^ name) :: List.map ~f:sexp_of_a bindings))
    )
end

module Dep_conf = struct
  type t =
    | File of String_with_vars.t
    | Alias of String_with_vars.t
    | Alias_rec of String_with_vars.t
    | Glob_files of String_with_vars.t
    | Source_tree of String_with_vars.t
    | Package of String_with_vars.t
    | Universe

  let t =
    let t =
      let sw = String_with_vars.t in
      sum
        [ "file"       , (sw >>| fun x -> File x)
        ; "alias"      , (sw >>| fun x -> Alias x)
        ; "alias_rec"  , (sw >>| fun x -> Alias_rec x)
        ; "glob_files" , (sw >>| fun x -> Glob_files x)
        ; "package"    , (sw >>| fun x -> Package x)
        ; "universe"   , return Universe
        ; "files_recursively_in",
          (let%map () =
            Syntax.renamed_in Stanza.syntax (1, 0) ~to_:"source_tree"
           and x = sw in
           Source_tree x)
        ; "source_tree",
          (let%map () = Syntax.since Stanza.syntax (1, 0)
           and x = sw in
           Source_tree x)
        ]
    in
    peek_exn >>= function
    | Template _ | Atom _ | Quoted_string _ ->
      String_with_vars.t >>| fun x -> File x
    | List _ -> t

  open Sexp
  let sexp_of_t = function
    | File t ->
      List [ Sexp.unsafe_atom_of_string "file"
           ; String_with_vars.sexp_of_t t ]
    | Alias t ->
      List [ Sexp.unsafe_atom_of_string "alias"
           ; String_with_vars.sexp_of_t t ]
    | Alias_rec t ->
      List [ Sexp.unsafe_atom_of_string "alias_rec"
           ; String_with_vars.sexp_of_t t ]
    | Glob_files t ->
      List [ Sexp.unsafe_atom_of_string "glob_files"
           ; String_with_vars.sexp_of_t t ]
    | Source_tree t ->
      List [ Sexp.unsafe_atom_of_string "files_recursively_in"
           ; String_with_vars.sexp_of_t t ]
    | Package t ->
      List [ Sexp.unsafe_atom_of_string "package"
           ; String_with_vars.sexp_of_t t]
    | Universe ->
      Sexp.unsafe_atom_of_string "universe"
end

module Preprocess = struct
  type pps = { loc : Loc.t; pps : (Loc.t * Pp.t) list; flags : string list }
  type t =
    | No_preprocessing
    | Action of Loc.t * Action.Unexpanded.t
    | Pps    of pps

  let t =
    sum
      [ "no_preprocessing", return No_preprocessing
      ; "action",
        (located Action.Unexpanded.t >>| fun (loc, x) ->
         Action (loc, x))
      ; "pps",
        (let%map loc = loc
         and pps, flags = Pps_and_flags.t in
         Pps { loc; pps; flags })
      ]

  let pps = function
    | Pps { pps; _ } -> pps
    | _ -> []
end

module Per_module = struct
  include Per_item.Make(Module.Name)

  let t ~default a =
    peek_exn >>= function
    | List (loc, Atom (_, A "per_module") :: _) ->
      sum [ "per_module",
            repeat
              (pair a module_names >>| fun (pp, names) ->
               let names =
                 List.map ~f:Module.Name.of_string (String.Set.to_list names)
               in
               (names, pp))
            >>| fun x ->
            of_mapping x ~default
            |> function
            | Ok t -> t
            | Error (name, _, _) ->
              of_sexp_errorf loc
                "module %s present in two different sets"
                (Module.Name.to_string name)
          ]
    | _ -> a >>| for_all
end

module Preprocess_map = struct
  type t = Preprocess.t Per_module.t
  let t = Per_module.t Preprocess.t ~default:Preprocess.No_preprocessing

  let no_preprocessing = Per_module.for_all Preprocess.No_preprocessing

  let find module_name t = Per_module.get t module_name

  let default = Per_module.for_all Preprocess.No_preprocessing

  module Pp_map = Map.Make(Pp)

  let pps t =
    Per_module.fold t ~init:Pp_map.empty ~f:(fun pp acc ->
      List.fold_left (Preprocess.pps pp) ~init:acc ~f:(fun acc (loc, pp) ->
        Pp_map.add acc pp loc))
    |> Pp_map.foldi ~init:[] ~f:(fun pp loc acc -> (loc, pp) :: acc)
end

module Lint = struct
  type t = Preprocess_map.t

  let t = Preprocess_map.t

  let default = Preprocess_map.default
  let no_lint = default
end

let field_oslu name = Ordered_set_lang.Unexpanded.field name

module Js_of_ocaml = struct

  type t =
    { flags            : Ordered_set_lang.Unexpanded.t
    ; javascript_files : string list
    }

  let t =
    record
      (let%map flags = field_oslu "flags"
       and javascript_files = field "javascript_files" (list string) ~default:[]
       in
       { flags; javascript_files })

  let default =
    { flags = Ordered_set_lang.Unexpanded.standard
    ; javascript_files = [] }
end

module Lib_dep = struct
  type choice =
    { required  : String.Set.t
    ; forbidden : String.Set.t
    ; file      : string
    }

  type select =
    { result_fn : string
    ; choices   : choice list
    ; loc       : Loc.t (* For error messages *)
    }

  type t =
    | Direct of (Loc.t * string)
    | Select of select

  let choice =
    enter (
      let%map loc = loc
      and preds, file =
        until_keyword "->"
          ~before:(let%map s = string in
                   let len = String.length s in
                   if len > 0 && s.[0] = '!' then
                     let s = String.sub s ~pos:1 ~len:(len - 1) in
                     Right s
                   else
                     Left s)
          ~after:file
      in
      match file with
      | None ->
        of_sexp_errorf loc "(<[!]libraries>... -> <file>) expected"
      | Some file ->
        let rec loop required forbidden = function
          | [] ->
            let common = String.Set.inter required forbidden in
            Option.iter (String.Set.choose common) ~f:(fun name ->
              of_sexp_errorf loc
                "library %S is both required and forbidden in this clause"
                name);
            { required
            ; forbidden
            ; file
            }
          | Left s :: l ->
            loop (String.Set.add required s) forbidden l
          | Right s :: l ->
            loop required (String.Set.add forbidden s) l
        in
        loop String.Set.empty String.Set.empty preds)

  let t =
    if_list
      ~then_:(
        enter
          (let%map loc = loc
           and () = keyword "select"
           and result_fn = file
           and () = keyword "from"
           and choices = repeat choice in
           Select { result_fn; choices; loc }))
      ~else_:(plain_string (fun ~loc s -> Direct (loc, s)))

  let to_lib_names = function
    | Direct (_, s) -> [s]
    | Select s ->
      List.fold_left s.choices ~init:String.Set.empty ~f:(fun acc x ->
        String.Set.union acc (String.Set.union x.required x.forbidden))
      |> String.Set.to_list

  let direct x = Direct x

  let of_pp (loc, pp) = Direct (loc, Pp.to_string pp)
end

module Lib_deps = struct
  type t = Lib_dep.t list

  type kind =
    | Required
    | Optional
    | Forbidden

  let t =
    let%map loc = loc
    and t = repeat Lib_dep.t
    in
    let add kind name acc =
      match String.Map.find acc name with
      | None -> String.Map.add acc name kind
      | Some kind' ->
        match kind, kind' with
        | Required, Required ->
          of_sexp_errorf loc "library %S is present twice" name
        | (Optional|Forbidden), (Optional|Forbidden) ->
          acc
        | Optional, Required | Required, Optional ->
          of_sexp_errorf loc
            "library %S is present both as an optional \
             and required dependency"
            name
        | Forbidden, Required | Required, Forbidden ->
          of_sexp_errorf loc
            "library %S is present both as a forbidden \
             and required dependency"
            name
    in
    ignore (
      List.fold_left t ~init:String.Map.empty ~f:(fun acc x ->
        match x with
        | Lib_dep.Direct (_, s) -> add Required s acc
        | Select { choices; _ } ->
          List.fold_left choices ~init:acc ~f:(fun acc c ->
            let acc =
              String.Set.fold c.Lib_dep.required ~init:acc ~f:(add Optional)
            in
            String.Set.fold c.forbidden ~init:acc ~f:(add Forbidden)))
      : kind String.Map.t);
    t

  let t = parens_removed_in_dune t

  let of_pps pps =
    List.map pps ~f:(fun pp -> Lib_dep.of_pp (Loc.none, pp))
end

module Buildable = struct
  type t =
    { loc                      : Loc.t
    ; modules                  : Ordered_set_lang.t
    ; modules_without_implementation : Ordered_set_lang.t
    ; libraries                : Lib_dep.t list
    ; preprocess               : Preprocess_map.t
    ; preprocessor_deps        : Dep_conf.t list
    ; lint                     : Preprocess_map.t
    ; flags                    : Ordered_set_lang.Unexpanded.t
    ; ocamlc_flags             : Ordered_set_lang.Unexpanded.t
    ; ocamlopt_flags           : Ordered_set_lang.Unexpanded.t
    ; js_of_ocaml              : Js_of_ocaml.t
    ; allow_overlapping_dependencies : bool
    }

  let modules_field name = Ordered_set_lang.field name

  let t =
    let%map loc = loc
    and preprocess =
      field "preprocess" Preprocess_map.t ~default:Preprocess_map.default
    and preprocessor_deps =
      field "preprocessor_deps" (list Dep_conf.t) ~default:[]
    and lint = field "lint" Lint.t ~default:Lint.default
    and modules = modules_field "modules"
    and modules_without_implementation =
      modules_field "modules_without_implementation"
    and libraries = field "libraries" Lib_deps.t ~default:[]
    and flags = field_oslu "flags"
    and ocamlc_flags = field_oslu "ocamlc_flags"
    and ocamlopt_flags = field_oslu "ocamlopt_flags"
    and js_of_ocaml =
      field "js_of_ocaml" Js_of_ocaml.t ~default:Js_of_ocaml.default
    and allow_overlapping_dependencies =
      field_b "allow_overlapping_dependencies"
    in
    { loc
    ; preprocess
    ; preprocessor_deps
    ; lint
    ; modules
    ; modules_without_implementation
    ; libraries
    ; flags
    ; ocamlc_flags
    ; ocamlopt_flags
    ; js_of_ocaml
    ; allow_overlapping_dependencies
    }

  let single_preprocess t =
    if Per_module.is_constant t.preprocess then
      Per_module.get t.preprocess (Module.Name.of_string "")
    else
      Preprocess.No_preprocessing
end

module Public_lib = struct
  type t =
    { name    : string
    ; package : Package.t
    ; sub_dir : string option
    }

  let public_name_field =
    map_validate
      (let%map project = Dune_project.get_exn ()
       and name = field_o "public_name" string in
       (project, name))
      ~f:(fun (project, name) ->
        match name with
        | None -> Ok None
        | Some s ->
          match String.split s ~on:'.' with
          | [] -> assert false
          | pkg :: rest ->
            match Pkg.resolve project (Package.Name.of_string pkg) with
            | Ok pkg ->
              Ok (Some
                    { package = pkg
                    ; sub_dir =
                        if rest = [] then None else
                          Some (String.concat rest ~sep:"/")
                    ; name    = s
                    })
            | Error _ as e -> e)
end

module Sub_system_info = struct
  type t = ..
  type sub_system = t = ..

  module type S = sig
    type t
    type sub_system += T of t
    val name   : Sub_system_name.t
    val loc    : t -> Loc.t
    val syntax : Syntax.t
    val parse  : t Sexp.Of_sexp.t
  end

  let all = Sub_system_name.Table.create ~default_value:None

  (* For parsing config files in the workspace *)
  let record_parser = ref return

  module Register(M : S) : sig end = struct
    open M

    let () =
      match Sub_system_name.Table.get all name with
      | Some _ ->
        Exn.code_error "Sub_system_info.register: already registered"
          [ "name", Sexp.To_sexp.string (Sub_system_name.to_string name) ];
      | None ->
        Sub_system_name.Table.set all ~key:name ~data:(Some (module M : S));
        let p = !record_parser in
        let name_s = Sub_system_name.to_string name in
        record_parser := (fun acc ->
          field_o name_s parse >>= function
          | None   -> p acc
          | Some x ->
            let acc = Sub_system_name.Map.add acc name (T x) in
            p acc)
  end

  let record_parser () = !record_parser Sub_system_name.Map.empty

  let get name = Option.value_exn (Sub_system_name.Table.get all name)
end

module Mode_conf = struct
  module T = struct
    type t =
      | Byte
      | Native
      | Best
    let compare (a : t) b = compare a b
  end
  include T

  let t =
    enum
      [ "byte"  , Byte
      ; "native", Native
      ; "best"  , Best
      ]

  let to_string = function
    | Byte -> "byte"
    | Native -> "native"
    | Best -> "best"

  let pp fmt t =
    Format.pp_print_string fmt (to_string t)

  let sexp_of_t t =
    Sexp.unsafe_atom_of_string (to_string t)

  module Set = struct
    include Set.Make(T)

    let t = list t >>| of_list

    let default = of_list [Byte; Best]

    let eval t ~has_native =
      let best : Mode.t =
        if has_native then
          Native
        else
          Byte
      in
      let has_best = mem t Best in
      let byte = mem t Byte || (has_best && best = Byte) in
      let native = best = Native && (mem t Native || has_best) in
      { Mode.Dict.byte; native }
  end
end

module Library = struct
  module Kind = struct
    type t =
      | Normal
      | Ppx_deriver
      | Ppx_rewriter

    let t =
      enum
        [ "normal"       , Normal
        ; "ppx_deriver"  , Ppx_deriver
        ; "ppx_rewriter" , Ppx_rewriter
        ]
  end

  type t =
    { name                     : string
    ; public                   : Public_lib.t option
    ; synopsis                 : string option
    ; install_c_headers        : string list
    ; ppx_runtime_libraries    : (Loc.t * string) list
    ; modes                    : Mode_conf.Set.t
    ; kind                     : Kind.t
    ; c_flags                  : Ordered_set_lang.Unexpanded.t
    ; c_names                  : string list
    ; cxx_flags                : Ordered_set_lang.Unexpanded.t
    ; cxx_names                : string list
    ; library_flags            : Ordered_set_lang.Unexpanded.t
    ; c_library_flags          : Ordered_set_lang.Unexpanded.t
    ; self_build_stubs_archive : string option
    ; virtual_deps             : (Loc.t * string) list
    ; wrapped                  : bool
    ; optional                 : bool
    ; buildable                : Buildable.t
    ; dynlink                  : bool
    ; project                  : Dune_project.t
    ; sub_systems              : Sub_system_info.t Sub_system_name.Map.t
    ; no_keep_locs             : bool
    ; dune_version             : Syntax.Version.t
    }

  let t =
    record
      (let%map buildable = Buildable.t
       and name = field "name" library_name
       and public = Public_lib.public_name_field
       and synopsis = field_o "synopsis" string
       and install_c_headers =
         field "install_c_headers" (list string) ~default:[]
       and ppx_runtime_libraries =
         field "ppx_runtime_libraries" (list (located string)) ~default:[]
       and c_flags = field_oslu "c_flags"
       and cxx_flags = field_oslu "cxx_flags"
       and c_names = field "c_names" (list c_name) ~default:[]
       and cxx_names = field "cxx_names" (list cxx_name) ~default:[]
       and library_flags = field_oslu "library_flags"
       and c_library_flags = field_oslu "c_library_flags"
       and virtual_deps =
         field "virtual_deps" (list (located string)) ~default:[]
       and modes = field "modes" Mode_conf.Set.t ~default:Mode_conf.Set.default
       and kind = field "kind" Kind.t ~default:Kind.Normal
       and wrapped = field "wrapped" bool ~default:true
       and optional = field_b "optional"
       and self_build_stubs_archive =
         field "self_build_stubs_archive" (option string) ~default:None
       and no_dynlink = field_b "no_dynlink"
       and no_keep_locs = field_b "no_keep_locs"
       and sub_systems =
         return () >>= fun () ->
         Sub_system_info.record_parser ()
       and project = Dune_project.get_exn ()
       and dune_version = Syntax.get_exn Stanza.syntax
       in
       { name
       ; public
       ; synopsis
       ; install_c_headers
       ; ppx_runtime_libraries
       ; modes
       ; kind
       ; c_names
       ; c_flags
       ; cxx_names
       ; cxx_flags
       ; library_flags
       ; c_library_flags
       ; self_build_stubs_archive
       ; virtual_deps
       ; wrapped
       ; optional
       ; buildable
       ; dynlink = not no_dynlink
       ; project
       ; sub_systems
       ; no_keep_locs
       ; dune_version
       })

  let has_stubs t =
    match t.c_names, t.cxx_names, t.self_build_stubs_archive with
    | [], [], None -> false
    | _            -> true

  let stubs_archive t ~dir ~ext_lib =
    Path.relative dir (sprintf "lib%s_stubs%s" t.name ext_lib)

  let dll t ~dir ~ext_dll =
    Path.relative dir (sprintf "dll%s_stubs%s" t.name ext_dll)

  let archive t ~dir ~ext =
    Path.relative dir (t.name ^ ext)

  let best_name t =
    match t.public with
    | None -> t.name
    | Some p -> p.name
end

module Install_conf = struct
  type file =
    { src : string
    ; dst : string option
    }

  let file =
    peek_exn >>= function
    | Atom (_, A src) -> junk >>| fun () -> { src; dst = None }
    | List (_, [Atom (_, A src); Atom (_, A "as"); Atom (_, A dst)]) ->
      junk >>> return { src; dst = Some dst }
    | sexp ->
      of_sexp_error (Sexp.Ast.loc sexp)
        "invalid format, <name> or (<name> as <install-as>) expected"

  type t =
    { section : Install.Section.t
    ; files   : file list
    ; package : Package.t
    }

  let t =
    record
      (let%map section = field "section" Install.Section.t
       and files = field "files" (list file)
       and package = Pkg.field
       in
       { section
       ; files
       ; package
       })
end

module Executables = struct

  module Link_mode = struct
    module T = struct
      type t =
        { mode : Mode_conf.t
        ; kind : Binary_kind.t
        }

      let compare a b =
        match compare a.mode b.mode with
        | Eq -> compare a.kind b.kind
        | ne -> ne
    end
    include T

    let make mode kind =
      { mode
      ; kind
      }

    let exe           = make Best Exe
    let object_       = make Best Object
    let shared_object = make Best Shared_object

    let byte_exe           = make Byte Exe

    let native_exe           = make Native Exe
    let native_object        = make Native Object
    let native_shared_object = make Native Shared_object

    let byte   = byte_exe
    let native = native_exe

    let installable_modes =
      [exe; native; byte]

    let simple_representations =
      [ "exe"           , exe
      ; "object"        , object_
      ; "shared_object" , shared_object
      ; "byte"          , byte
      ; "native"        , native
      ]

    let simple =
      Sexp.Of_sexp.enum simple_representations

    let t =
      peek_exn >>= function
      | List _ ->
        enter (let%map mode = Mode_conf.t
               and kind = Binary_kind.t in
               { mode; kind })
      | _ -> simple

    let simple_sexp_of_t link_mode =
      let is_ok (_, candidate) =
        compare candidate link_mode = Eq
      in
      match List.find ~f:is_ok simple_representations with
      | Some (s, _) -> Some (Sexp.unsafe_atom_of_string s)
      | None -> None

    let sexp_of_t link_mode =
      match simple_sexp_of_t link_mode with
      | Some s -> s
      | None ->
        let { mode; kind } = link_mode in
        Sexp.To_sexp.pair Mode_conf.sexp_of_t Binary_kind.sexp_of_t (mode, kind)

    module Set = struct
      include Set.Make(T)

      let t =
        located (list t) >>| fun (loc, l) ->
        match l with
        | [] -> of_sexp_errorf loc "No linking mode defined"
        | l ->
          let t = of_list l in
          if (mem t native_exe           && mem t exe          ) ||
             (mem t native_object        && mem t object_      ) ||
             (mem t native_shared_object && mem t shared_object) then
            of_sexp_errorf loc
              "It is not allowed use both native and best \
               for the same binary kind."
          else
            t

      let default =
        of_list
          [ byte
          ; exe
          ]

      let best_install_mode t =
        List.find ~f:(mem t) installable_modes
    end
  end

  type t =
    { names      : (Loc.t * string) list
    ; link_flags : Ordered_set_lang.Unexpanded.t
    ; link_deps  : Dep_conf.t list
    ; modes      : Link_mode.Set.t
    ; buildable  : Buildable.t
    }

  let common =
    let%map buildable = Buildable.t
    and (_ : bool) = field "link_executables" ~default:true
                       (Syntax.deleted_in Stanza.syntax (1, 0) >>> bool)
    and link_deps = field "link_deps" (list Dep_conf.t) ~default:[]
    and link_flags = field_oslu "link_flags"
    and modes = field "modes" Link_mode.Set.t ~default:Link_mode.Set.default
    and () = map_validate
               (field "inline_tests" (repeat junk >>| fun _ -> true) ~default:false)
               ~f:(function
                 | false -> Ok ()
                 | true  ->
                   Error
                     "Inline tests are only allowed in libraries.\n\
                      See https://github.com/ocaml/dune/issues/745 for more details.")
    and package = field_o "package" (let%map loc = loc
                                     and s = string in
                                     (loc, s))
    and project = Dune_project.get_exn ()
    and file_kind = Stanza.file_kind ()
    in
    fun names public_names ~multi ->
      let t =
        { names
        ; link_flags
        ; link_deps
        ; modes
        ; buildable
        }
      in
      let has_public_name =
        List.exists ~f:Option.is_some public_names
      in
      let to_install =
        match Link_mode.Set.best_install_mode t.modes with
        | None when has_public_name ->
          let mode_to_string mode =
            " - " ^ Sexp.to_string ~syntax:Dune (Link_mode.sexp_of_t mode) in
          let mode_strings = List.map ~f:mode_to_string Link_mode.installable_modes in
          Loc.fail
            buildable.loc
            "No installable mode found for %s.\n\
             One of the following modes is required:\n\
             %s"
            (if multi then "these executables" else "this executable")
            (String.concat ~sep:"\n" mode_strings)
        | None -> []
        | Some mode ->
          let ext =
            match mode.mode with
            | Native | Best -> ".exe"
            | Byte -> ".bc"
          in
          List.map2 names public_names
            ~f:(fun (_, name) pub ->
              match pub with
              | None -> None
              | Some pub -> Some ({ Install_conf.
                                    src = name ^ ext
                                  ; dst = Some pub
                                  }))
          |> List.filter_map ~f:(fun x -> x)
      in
      match to_install with
      | [] -> begin
          match package with
          | None -> (t, None)
          | Some (loc, _) ->
            let func =
              match file_kind with
              | Jbuild -> Loc.warn
              | Dune   -> Loc.fail
            in
            func loc
              "This field is useless without a (public_name%s ...) field."
              (if multi then "s" else "");
            (t, None)
        end
      | files ->
        let package =
          match
            match package with
            | None ->
              (buildable.loc, Pkg.default project)
            | Some (loc, name) ->
              (loc, Pkg.resolve project (Package.Name.of_string name))
          with
          | (_, Ok x) -> x
          | (loc, Error msg) ->
            of_sexp_errorf loc "%s" msg
        in
        (t, Some { Install_conf. section = Bin; files; package })

  let public_name =
    string >>| function
    | "-" -> None
    | s   -> Some s

  let multi =
    record
      (let%map names, public_names =
         map_validate
           (let%map names = field "names" (list (located string))
            and pub_names = field_o "public_names" (list public_name) in
            (names, pub_names))
           ~f:(fun (names, public_names) ->
             match public_names with
             | None -> Ok (names, List.map names ~f:(fun _ -> None))
             | Some public_names ->
               if List.length public_names = List.length names then
                 Ok (names, public_names)
               else
                 Error "The list of public names must be of the same \
                        length as the list of names")
       and f = common in
       f names public_names ~multi:true)

  let single =
    record
      (let%map name = field "name" (located string)
       and public_name = field_o "public_name" string
       and f = common in
       f [name] [public_name] ~multi:false)
end

module Rule = struct
  module Targets = struct
    type t =
      | Static of string list (* List of files in the current directory *)
      | Infer
  end


  module Mode = struct
    type t =
      | Standard
      | Fallback
      | Promote
      | Promote_but_delete_on_clean
      | Not_a_rule_stanza
      | Ignore_source_files

    let t =
      enum
        [ "standard"           , Standard
        ; "fallback"           , Fallback
        ; "promote"            , Promote
        ; "promote-until-clean", Promote_but_delete_on_clean
        ]

    let field = field "mode" t ~default:Standard
  end

  type t =
    { targets  : Targets.t
    ; deps     : Dep_conf.t Bindings.t
    ; action   : Loc.t * Action.Unexpanded.t
    ; mode     : Mode.t
    ; locks    : String_with_vars.t list
    ; loc      : Loc.t
    }

  type action_or_field = Action | Field

  let atom_table =
    String.Map.of_list_exn
      [ "run"                         , Action
      ; "chdir"                       , Action
      ; "setenv"                      , Action
      ; "with-stdout-to"              , Action
      ; "with-stderr-to"              , Action
      ; "with-outputs-to"             , Action
      ; "ignore-stdout"               , Action
      ; "ignore-stderr"               , Action
      ; "ignore-outputs"              , Action
      ; "progn"                       , Action
      ; "echo"                        , Action
      ; "cat"                         , Action
      ; "copy"                        , Action
      ; "copy#"                       , Action
      ; "copy-and-add-line-directive" , Action
      ; "system"                      , Action
      ; "bash"                        , Action
      ; "write-file"                  , Action
      ; "diff"                        , Action
      ; "diff?"                       , Action
      ; "targets"                     , Field
      ; "deps"                        , Field
      ; "action"                      , Field
      ; "locks"                       , Field
      ; "fallback"                    , Field
      ; "mode"                        , Field
      ]

  let short_form =
    located Action.Unexpanded.t >>| fun (loc, action) ->
    { targets  = Infer
    ; deps     = Bindings.empty
    ; action   = (loc, action)
    ; mode     = Standard
    ; locks    = []
    ; loc      = loc
    }

  let long_form =
    let%map loc = loc
    and action = field "action" (located Action.Unexpanded.t)
    and targets = field "targets" (list file_in_current_dir)
    and deps = field "deps" (Bindings.t Dep_conf.t) ~default:Bindings.empty
    and locks = field "locks" (list String_with_vars.t) ~default:[]
    and mode =
      map_validate
        (field_b
           ~check:(Syntax.renamed_in Stanza.syntax (1, 0)
                     ~to_:"(mode fallback)")
           "fallback" >>= fun fallback ->
         field_o "mode" Mode.t >>= fun mode ->
         return (fallback, mode))
        ~f:(function
          | true, Some _ ->
            Error "Cannot use both (fallback) and (mode ...) at the \
                   same time.\n\
                   (fallback) is the same as (mode fallback), \
                   please use the latter in new code."
          | false, Some mode -> Ok mode
          | true, None -> Ok Fallback
          | false, None -> Ok Standard)
    in
    { targets = Static targets
    ; deps
    ; action
    ; mode
    ; locks
    ; loc
    }

  let jbuild_syntax =
    peek_exn >>= function
    | List (_, (Atom _ :: _)) -> short_form
    | _ -> record long_form

  let dune_syntax =
    peek_exn >>= function
    | List (_, Atom (loc, A s) :: _) -> begin
      match String.Map.find atom_table s with
      | None ->
        of_sexp_errorf loc ~hint:{ on = s
                                 ; candidates = String.Map.keys atom_table
                                 }
          "Unknown action or rule field."
      | Some Field -> fields long_form
      | Some Action -> short_form
    end
    | sexp ->
      of_sexp_errorf (Sexp.Ast.loc sexp)
        "S-expression of the form (<atom> ...) expected"

  let t =
    Syntax.get_exn Stanza.syntax >>= fun ver ->
    if ver < (1, 0) then
      jbuild_syntax
    else
      dune_syntax

  type lex_or_yacc =
    { modules : string list
    ; mode    : Mode.t
    }

  let ocamllex_jbuild =
    enter
      (if_list
         ~then_:(
           record
             (let%map modules = field "modules" (list string)
              and mode = Mode.field in
              { modules; mode }))
         ~else_:(
           repeat string >>| fun modules ->
           { modules
           ; mode  = Standard
           }))

  let ocamllex_dune =
    if_eos
      ~then_:(
        return
          { modules = []
          ; mode  = Standard
          })
      ~else_:(
        if_list
          ~then_:(
            record
              (let%map modules = field "modules" (list string)
               and mode = Mode.field in
               { modules; mode }))
          ~else_:(
            repeat string >>| fun modules ->
            { modules
            ; mode  = Standard
            }))

  let ocamllex =
    Syntax.get_exn Stanza.syntax >>= fun ver ->
    if ver < (1, 0) then
      ocamllex_jbuild
    else
      ocamllex_dune

  let ocamlyacc = ocamllex

  let ocamllex_to_rule loc { modules; mode } =
    let module S = String_with_vars in
    List.map modules ~f:(fun name ->
      let src = name ^ ".mll" in
      let dst = name ^ ".ml"  in
      { targets = Static [dst]
      ; deps    = Bindings.singleton (Dep_conf.File (S.virt_text __POS__ src))
      ; action  =
          (loc,
           Chdir
             (S.virt_var __POS__ "workspace_root",
              Run (S.virt_text __POS__ "ocamllex",
                   [ S.virt_text __POS__ "-q"
                   ; S.virt_text __POS__ "-o"
                   ; S.virt_var __POS__ "targets"
                   ; S.virt_var __POS__"deps"
                   ])))
      ; mode
      ; locks = []
      ; loc
      })

  let ocamlyacc_to_rule loc { modules; mode } =
    let module S = String_with_vars in
    List.map modules ~f:(fun name ->
      let src = name ^ ".mly" in
      { targets = Static [name ^ ".ml"; name ^ ".mli"]
      ; deps    = Bindings.singleton (Dep_conf.File (S.virt_text __POS__ src))
      ; action  =
          (loc,
           Chdir
             (S.virt_var __POS__ "workspace_root",
              Run (S.virt_text __POS__ "ocamlyacc",
                   [S.virt_var __POS__ "deps"])))
      ; mode
      ; locks = []
      ; loc
      })
end

module Menhir = struct
  type t =
    { merge_into : string option
    ; flags      : Ordered_set_lang.Unexpanded.t
    ; modules    : string list
    ; mode       : Rule.Mode.t
    ; loc        :  Loc.t
    }

  let syntax =
    Syntax.create
      ~name:"menhir"
      ~desc:"the menhir extension"
      [ (1, 0) ]

  let t =
    record
      (let%map merge_into = field_o "merge_into" string
       and flags = field_oslu "flags"
       and modules = field "modules" (list string)
       and mode = Rule.Mode.field in
       { merge_into
       ; flags
       ; modules
       ; mode
       ; loc = Loc.none
       })

  type Stanza.t += T of t

  let () =
    Dune_project.Extension.register syntax
      (return [ "menhir", t >>| fun x -> [T x] ])

  (* Syntax for jbuild files *)
  let jbuild_syntax =
    record
      (let%map merge_into = field_o "merge_into" string
       and flags = field_oslu "flags"
       and modules = field "modules" (list string)
       and mode = Rule.Mode.field in
       { merge_into
       ; flags
       ; modules
       ; mode
       ; loc = Loc.none
       })
end

module Alias_conf = struct
  type t =
    { name    : string
    ; deps    : Dep_conf.t Bindings.t
    ; action  : (Loc.t * Action.Unexpanded.t) option
    ; locks   : String_with_vars.t list
    ; package : Package.t option
    }

  let alias_name =
    plain_string (fun ~loc s ->
      if Filename.basename s <> s then
        of_sexp_errorf loc "%S is not a valid alias name" s
      else
        s)

  let t =
    record
      (let%map name = field "name" alias_name
       and package = field_o "package" Pkg.t
       and action = field_o "action" (located Action.Unexpanded.t)
       and locks = field "locks" (list String_with_vars.t) ~default:[]
       and deps = field "deps" (Bindings.t Dep_conf.t) ~default:Bindings.empty
       in
       { name
       ; deps
       ; action
       ; package
       ; locks
       })
end

module Tests = struct
  type t =
    { exes    : Executables.t
    ; locks   : String_with_vars.t list
    ; package : Package.t option
    ; deps    : Dep_conf.t Bindings.t
    }

  let gen_parse names =
    record
      (let%map buildable = Buildable.t
       and link_flags = field_oslu "link_flags"
       and names = names
       and package = field_o "package" Pkg.t
       and locks = field "locks" (list String_with_vars.t) ~default:[]
       and modes = field "modes" Executables.Link_mode.Set.t
                     ~default:Executables.Link_mode.Set.default
       and deps = field "deps" (Bindings.t Dep_conf.t) ~default:Bindings.empty
       in
       { exes =
           { Executables.
             link_flags
           ; link_deps = []
           ; modes
           ; buildable
           ; names
           }
       ; locks
       ; package
       ; deps
       })

  let multi = gen_parse (field "names" (list (located string)))

  let single = gen_parse (field "name" (located string) >>| List.singleton)
end

module Copy_files = struct
  type t = { add_line_directive : bool
           ; glob : String_with_vars.t
           }

  let t = String_with_vars.t
end

module Documentation = struct
  type t =
    { loc : Loc.t
    ; package : Package.t
    ; mld_files : Ordered_set_lang.t
    }

  let t =
    record
      (let%map package = Pkg.field
       and mld_files = Ordered_set_lang.field "mld_files"
       and loc = loc in
       { loc
       ; package
       ; mld_files
       }
      )
end

type Stanza.t +=
  | Library     of Library.t
  | Executables of Executables.t
  | Rule        of Rule.t
  | Install     of Install_conf.t
  | Alias       of Alias_conf.t
  | Copy_files  of Copy_files.t
  | Documentation of Documentation.t
  | Tests       of Tests.t

module Stanzas = struct
  type t = Stanza.t list

  type syntax = OCaml | Plain

  let rules l = List.map l ~f:(fun x -> Rule x)

  let execs (exe, install) =
    match install with
    | None -> [Executables exe]
    | Some i -> [Executables exe; Install i]

  type Stanza.t += Include of Loc.t * string

  type constructors = (string * Stanza.t list Sexp.Of_sexp.t) list

  let stanzas : constructors =
    [ "library",
      (let%map x = Library.t in
       [Library x])
    ; "executable" , Executables.single >>| execs
    ; "executables", Executables.multi  >>| execs
    ; "rule",
      (let%map loc = loc
       and x = Rule.t in
       [Rule { x with loc }])
    ; "ocamllex",
      (let%map loc = loc
       and x = Rule.ocamllex in
       (rules (Rule.ocamllex_to_rule loc x)))
    ; "ocamlyacc",
      (let%map loc = loc
       and x = Rule.ocamlyacc in
       rules (Rule.ocamlyacc_to_rule loc x))
    ; "install",
      (let%map x = Install_conf.t in
       [Install x])
    ; "alias",
      (let%map x = Alias_conf.t in
       [Alias x])
    ; "copy_files",
      (let%map glob = Copy_files.t in
       [Copy_files {add_line_directive = false; glob}])
    ; "copy_files#",
      (let%map glob = Copy_files.t in
       [Copy_files {add_line_directive = true; glob}])
    ; "include",
      (let%map loc = loc
       and fn = relative_file in
       [Include (loc, fn)])
    ; "documentation",
      (let%map d = Documentation.t in
       [Documentation d])
    ; "jbuild_version",
      (let%map () = Syntax.deleted_in Stanza.syntax (1, 0)
       and _ = Jbuild_version.t in
       [])
    ; "tests",
      (let%map () = Syntax.since Stanza.syntax (1, 0)
       and t = Tests.multi in
       [Tests t])
    ; "test",
      (let%map () = Syntax.since Stanza.syntax (1, 0)
       and t = Tests.single in
       [Tests t])
    ; "env",
      (let%map x = Dune_env.Stanza.t in
       [Dune_env.T x])
    ]

  let jbuild_parser =
    (* The menhir stanza was part of the vanilla jbuild
       syntax. Starting from Dune 1.0, it is presented as an
       extension with its own version. *)
    let stanzas =
      stanzas @
      [ "menhir",
        (let%map loc = loc
         and x = Menhir.jbuild_syntax in
         [Menhir.T { x with loc }])
      ]
    in
    Syntax.set Stanza.syntax (0, 0) (sum stanzas)

  let () =
    Dune_project.Lang.register Stanza.syntax stanzas

  exception Include_loop of Path.t * (Loc.t * Path.t) list

  let rec parse stanza_parser ~lexer ~current_file ~include_stack sexps =
    List.concat_map sexps ~f:(Sexp.Of_sexp.parse stanza_parser Univ_map.empty)
    |> List.concat_map ~f:(function
      | Include (loc, fn) ->
        let include_stack = (loc, current_file) :: include_stack in
        let dir = Path.parent_exn current_file in
        let current_file = Path.relative dir fn in
        if not (Path.exists current_file) then
          Loc.fail loc "File %s doesn't exist."
            (Path.to_string_maybe_quoted current_file);
        if List.exists include_stack ~f:(fun (_, f) -> f = current_file) then
          raise (Include_loop (current_file, include_stack));
        let sexps = Io.Sexp.load ~lexer current_file ~mode:Many in
        parse stanza_parser sexps ~lexer ~current_file ~include_stack
      | stanza -> [stanza])

  let parse ~file ~kind (project : Dune_project.t) sexps =
    let (stanza_parser, lexer) =
      let (parser, lexer) =
        match (kind : File_tree.Dune_file.Kind.t) with
        | Jbuild -> (jbuild_parser, Usexp.Lexer.jbuild_token)
        | Dune   -> (project.stanza_parser, Usexp.Lexer.token)
      in
      (Dune_project.set project parser, lexer)
    in
    let stanzas =
      try
        parse stanza_parser sexps ~lexer ~include_stack:[] ~current_file:file
      with
      | Include_loop (_, []) -> assert false
      | Include_loop (file, last :: rest) ->
        let loc = fst (Option.value (List.last rest) ~default:last) in
        let line_loc (loc, file) =
          sprintf "%s:%d"
            (Path.to_string_maybe_quoted file)
            loc.Loc.start.pos_lnum
        in
        Loc.fail loc
          "Recursive inclusion of jbuild files detected:\n\
           File %s is included from %s%s"
          (Path.to_string_maybe_quoted file)
          (line_loc last)
          (String.concat ~sep:""
             (List.map rest ~f:(fun x ->
                sprintf
                  "\n--> included from %s"
                  (line_loc x))))
    in
    match
      List.filter_map stanzas
        ~f:(function Dune_env.T e -> Some e | _ -> None)
    with
    | _ :: e :: _ ->
      Loc.fail e.loc "The 'env' stanza cannot appear more than once"
    | _ -> stanzas
end
