(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Expression
open Pyre
open Statement

module Callable = AnnotatedCallable
module Attribute = AnnotatedAttribute


type t = Class.t Node.t
[@@deriving compare, eq, sexp, show, hash]


type decorator = {
  name: string;
  arguments: (Expression.t Expression.Call.Argument.t list) option
}
[@@deriving compare, eq, sexp, show, hash]


module AttributeCache = struct
  type t = {
    transitive: bool;
    class_attributes: bool;
    include_generated_attributes: bool;
    name: Reference.t;
    instantiated: Type.t;
  }
  [@@deriving compare, sexp, hash]


  include Hashable.Make(struct
      type nonrec t = t
      let compare = compare
      let hash = Hashtbl.hash
      let hash_fold_t = hash_fold_t
      let sexp_of_t = sexp_of_t
      let t_of_sexp = t_of_sexp
    end)


  let cache: Attribute.Table.t Table.t =
    Table.create ~size:1023 ()


  let clear () =
    Table.clear cache
end


let name_equal
    { Node.value = { Class.name = left; _ }; _ }
    { Node.value = { Class.name = right; _ }; _ } =
  Reference.equal left right


let create definition =
  definition


let name { Node.value = { Class.name; _ }; _ } =
  name


let bases { Node.value = { Class.bases; _ }; _ } =
  bases


let get_decorator { Node.value = { Class.decorators; _ }; _ } ~decorator =
  let matches target decorator =
    match decorator with
    | { Node.value = Access (SimpleAccess access); _ } ->
        begin
          match Expression.Access.name_and_arguments ~call:access with
          | Some { callee = name; arguments } when String.equal name target ->
              let convert_argument { Argument.name; value } =
                { Call.Argument.name; value }
              in
              Some {
                name;
                arguments = Some (List.map ~f:convert_argument arguments)
              }
          | None when String.equal (Access.show access) target ->
              Some { name = Access.show access; arguments = None }
          | _ ->
              None
        end
    | { Node.value = Call { callee; arguments }; _ }
      when String.equal target (Expression.show callee) ->
        Some {
          name = Expression.show callee;
          arguments = Some arguments
        }
    | { Node.value = Name _; _ }
      when String.equal target (Expression.show decorator) ->
        Some {
          name = Expression.show decorator;
          arguments = None;
        }
    | _ ->
        None
  in
  List.filter_map ~f:(matches decorator) decorators


let annotation { Node.value = { Class.name; _ }; _ } =
  Type.Primitive (Reference.show name)


let successors { Node.value = { Class.name; _ }; _ } ~resolution =
  Type.Primitive (Reference.show name)
  |> Resolution.class_metadata resolution
  >>| (fun { Resolution.successors; _ } -> successors)
  |> Option.value ~default:[]


let successors_fold class_node ~resolution ~f ~initial =
  successors class_node ~resolution
  |> List.fold ~init:initial ~f


module Method = struct
  type t = {
    define: Define.t;
    parent: Type.t;
  }
  [@@deriving compare, eq, sexp, show, hash]


  let create ~define ~parent =
    { define; parent }


  let name { define; _ } =
    Define.unqualified_name define


  let define { define; _ } =
    define


  let parent { parent; _ } =
    parent


  let parameter_annotations
      { define = { Define.signature = { parameters; _ }; _ }; _ }
      ~resolution =
    let element { Node.value = { Parameter.name; annotation; _ }; _ } =
      let annotation =
        (annotation
         >>| fun annotation -> Resolution.parse_annotation resolution annotation)
        |> Option.value ~default:Type.Top
      in
      name, annotation
    in
    List.map parameters ~f:element


  let return_annotation
      { define = { Define.signature = { return_annotation; async; _ }; _ } as define; _ }
      ~resolution =
    let annotation =
      Option.value_map
        return_annotation
        ~f:(Resolution.parse_annotation resolution)
        ~default:Type.Top
    in
    if async then
      Type.awaitable annotation
    else
    if Define.is_coroutine define then
      begin
        match annotation with
        | Type.Parametric { name; parameters = [_; _; return_annotation] }
          when String.equal name "typing.Generator" ->
            Type.awaitable return_annotation
        | _ ->
            Type.Top
      end
    else
      annotation
end


let find_propagated_type_variables bases ~resolution =
  let find_type_variables { Expression.Call.Argument.value; _ } =
    Resolution.parse_annotation ~allow_invalid_type_parameters:true resolution value
    |> Type.Variable.all_free_variables
    |> List.map ~f:(fun variable -> Type.Variable variable)
  in
  List.concat_map ~f:find_type_variables bases
  |> List.dedup ~compare:Type.compare


let generics { Node.value = { Class.bases; _ }; _ } ~resolution =
  let generic { Expression.Call.Argument.value; _ } =
    let annotation =
      Resolution.parse_annotation ~allow_invalid_type_parameters:true resolution value
    in
    match annotation with
    | Type.Parametric { parameters; _ }
      when Type.is_generic annotation ->
        Some parameters
    | Type.Parametric { parameters; _ }
      when Type.is_protocol annotation ->
        Some parameters
    | _ ->
        None
  in
  begin
    match List.find_map ~f:generic bases with
    | None -> find_propagated_type_variables bases ~resolution
    | Some parameters -> parameters
  end


let inferred_generic_base { Node.value = { Class.bases; _ }; _ } ~resolution =
  let is_generic { Expression.Call.Argument.value; _ } =
    let primitive, _ =
      Resolution.parse_annotation ~allow_invalid_type_parameters:true resolution value
      |> Type.split
    in
    Type.equal primitive Type.generic
  in
  if List.exists ~f:is_generic bases then
    []
  else
    let variables = find_propagated_type_variables bases ~resolution in
    if List.is_empty variables then
      []
    else
      [{
        Expression.Call.Argument.name = None;
        value =
          Type.parametric "typing.Generic" variables
          |> Type.expression ~convert:true;
      }]


let constraints ?target ?parameters definition ~instantiated ~resolution =
  let target = Option.value ~default:definition target in
  let parameters =
    match parameters with
    | None ->
        generics ~resolution target
    | Some parameters ->
        parameters
  in
  let right =
    let target = annotation target in
    match target with
    | Primitive name ->
        Type.parametric name parameters
    | _ ->
        target
  in
  match instantiated, right with
  | Type.Primitive name, Parametric { name = right_name; _ } when String.equal name right_name ->
      (* TODO(T42259381) This special case is only necessary because constructor calls attributes
         with an "instantiated" type of a bare parametric, which will fill with Anys *)
      Type.Map.empty
  | _ ->
      Resolution.solve_less_or_equal
        resolution
        ~constraints:TypeConstraints.empty
        ~left:instantiated
        ~right
      |> List.filter_map ~f:(Resolution.solve_constraints resolution)
      |> List.hd
      (* TODO(T39598018): error in this case somehow, something must be wrong *)
      |> Option.value ~default:Type.Map.empty


let superclasses definition ~resolution =
  successors ~resolution definition
  |> List.filter_map ~f:(fun name -> Resolution.class_definition resolution (Type.Primitive name))
  |> List.map ~f:create


let immediate_superclasses definition ~resolution =
  let (module Handler: TypeOrder.Handler) = Resolution.order resolution in
  let annotation = annotation definition in

  let has_definition { TypeOrder.Target.target; _ } =
    Handler.find (Handler.annotations ()) target
    >>= Resolution.class_definition resolution
    >>| create
  in
  Handler.find (Handler.indices ()) annotation
  >>= Handler.find (Handler.edges ())
  |> Option.value ~default:[]
  |> List.find_map ~f:has_definition


let metaclass definition ~resolution =
  let get_metaclass { Node.value = { Class.bases; _ }; _ } =
    let get_metaclass = function
      | { Expression.Call.Argument.name = Some { Node.value = "metaclass"; _ }; value } ->
          Some (Resolution.parse_annotation resolution value)
      | _ ->
          None
    in
    List.find_map ~f:get_metaclass bases
  in
  (* See https://docs.python.org/3/reference/datamodel.html#determining-the-appropriate-metaclass
     for why we need to consider all metaclasses. *)
  let metaclass_candidates =
    definition :: superclasses ~resolution definition
    |> List.filter_map ~f:get_metaclass
  in
  match metaclass_candidates with
  | [] ->
      Type.Primitive "type"
  | first :: candidates ->
      let candidate = List.fold candidates ~init:first ~f:(Resolution.meet resolution) in
      match candidate with
      | Type.Bottom ->
          (* If we get Bottom here, we don't have a "most derived metaclass", so default to one. *)
          first
      | _ ->
          candidate


let methods ({ Node.value = { Class.body; _ }; _ } as definition) =
  let extract_define = function
    | { Node.value = Define define; _ } ->
        Some (Method.create ~define ~parent:(annotation definition))
    | _ ->
        None
  in
  List.filter_map ~f:extract_define body


let is_protocol { Node.value = { Class.bases; _ }; _ } =
  let is_protocol { Call.Argument.name; value = { Node.value; _ } } =
    match name, value with
    | None, Access (SimpleAccess ((Identifier "typing") :: (Identifier "Protocol") :: _))
    | None,
      Access (SimpleAccess ((Identifier "typing_extensions") :: (Identifier "Protocol") :: _)) ->
        true
    | None,
      Call {
        callee = {
          Node.value = Name (Name.Attribute {
              base = {
                Node.value = Name (Name.Attribute {
                    base = { Node.value = Name (Name.Identifier typing); _ };
                    attribute = "Protocol";
                  });
                _;
              };
              attribute = "__getitem__";
            });
          _;
        };
        _;
      }
    | None,
      Name (Name.Attribute {
          base = { Node.value = Name (Name.Identifier typing); _ };
          attribute = "Protocol";
        }) when (String.equal typing "typing") || (String.equal typing "typing_extensions") ->
        true
    | _ ->
        false
  in
  List.exists ~f:is_protocol bases


let create_attribute
    ~resolution
    ~parent
    ?instantiated
    ?(defined = true)
    ?(inherited = false)
    ?(default_class_attribute = false)
    {
      Node.location;
      value = {
        Statement.Attribute.name = attribute_name;
        annotation = attribute_annotation;
        defines;
        value;
        async;
        setter;
        property;
        primitive;
        toplevel;
        final;
      };
    } =
  let class_annotation = annotation parent in
  let initialized =
    match value with
    | Some { Node.value = Ellipsis; _ }
    | None ->
        false
    | _ ->
        true
  in

  (* Account for class attributes. *)
  let annotation, class_attribute =
    (attribute_annotation
     >>| Resolution.parse_annotation resolution
     >>| (fun annotation ->
         match Type.class_variable_value annotation with
         | Some annotation -> Some annotation, true
         | _ -> Some annotation, false))
    |> Option.value ~default:(None, default_class_attribute)
  in

  (* Handle enumeration attributes. *)
  let annotation, value, class_attribute =
    let superclasses =
      superclasses ~resolution parent
      |> List.map ~f:(fun definition -> name definition |> Reference.show)
      |> String.Set.of_list
    in
    if not (Set.mem Recognized.enumeration_classes (Type.show class_annotation)) &&
       not (Set.is_empty (Set.inter Recognized.enumeration_classes superclasses)) &&
       not inherited &&
       primitive then
      Some class_annotation, None, true  (* Enums override values. *)
    else
      annotation, value, class_attribute
  in

  (* Handle Callables *)
  let annotation =
    let instantiated =
      match instantiated with
      | Some instantiated ->
          instantiated
      | None ->
          class_annotation
    in
    match defines with
    | Some (({ Define.signature = { Define.name; _ }; _ } as define :: _) as defines) ->
        let parent =
          if Define.is_static_method define then
            None
          else if Define.is_class_method define then
            Some (Type.meta instantiated)
          else if class_attribute then
            (* Keep first argument around when calling instance methods from class attributes. *)
            None
          else
            Some instantiated
        in
        let apply_decorators define =
          Define.is_overloaded_method define, Callable.apply_decorators ~define ~resolution
        in
        List.map defines ~f:apply_decorators
        |> Callable.create ~parent ~name:(Reference.show name)
        |> (fun callable -> Some (Type.Callable callable))
    | _ ->
        annotation
  in

  let annotation =
    match annotation, value with
    | Some annotation, Some value ->
        Annotation.create_immutable
          ~global:true
          ~original:(Some annotation)
          (if setter then
             (Resolution.parse_annotation resolution value)
           else
             annotation)
    | Some annotation, None ->
        Annotation.create_immutable ~global:true annotation
    | None, Some value ->
        let literal_value_annotation =
          if setter then
            Resolution.parse_annotation resolution value
          else
            Resolution.resolve_literal resolution value
        in
        let is_dataclass_attribute =
          let get_dataclass_decorator annotated =
            get_decorator annotated ~decorator:"dataclasses.dataclass"
            @ get_decorator annotated ~decorator:"dataclass"
          in
          not (List.is_empty (get_dataclass_decorator parent))
        in
        if not (Type.is_partially_typed literal_value_annotation) &&
           not is_dataclass_attribute &&
           toplevel
        then
          (* Treat literal attributes as having been explicitly annotated. *)
          Annotation.create_immutable
            ~global:true
            literal_value_annotation
        else
          Annotation.create_immutable
            ~global:true
            ~original:(Some Type.Top)
            (Resolution.parse_annotation resolution value)
    | _ ->
        Annotation.create Type.Top
  in

  (* Special case properties with type variables. *)
  let annotation =
    let free_variables =
      let variables =
        Annotation.annotation annotation
        |> Type.Variable.all_free_variables
        |> List.map ~f:(fun variable -> Type.Variable variable)
        |> Type.Set.of_list
      in
      let generics =
        generics parent ~resolution
        |> Type.Set.of_list
      in
      Set.diff variables generics
      |> Set.to_list
    in
    if property && not (List.is_empty free_variables) then
      let constraints =
        let instantiated = Option.value instantiated ~default:class_annotation in
        List.fold
          free_variables
          ~init:Type.Map.empty
          ~f:(fun map variable -> Map.set map ~key:variable ~data:instantiated)
        |> Map.find
      in
      Annotation.annotation annotation
      |> Type.instantiate ~constraints
      |> Annotation.create_immutable ~global:true ~original:(Some Type.Top)
    else
      annotation
  in

  (* Special cases *)
  let annotation =
    match instantiated, attribute_name, annotation with
    | Some (Type.TypedDictionary { fields; total; _ }),
      method_name,
      { annotation = Type.Callable callable; _ } ->
        Type.TypedDictionary.special_overloads ~fields ~method_name ~total
        >>| (fun overloads ->
            {
              annotation with
              annotation =
                Type.Callable {
                  callable with
                  implementation = { annotation = Type.Top; parameters = Undefined };
                  overloads;
                };
            })
        |> Option.value ~default:annotation
    | Some (Type.Tuple (Bounded members)),
      "__getitem__",
      { annotation = Type.Callable ({ overloads; _ } as callable); _ } ->
        let overload index member =
          {
            Type.Callable.annotation = member;
            parameters = Defined [
                Named { name = "x"; annotation = Type.literal_integer index; default = false };
              ];
          }
        in
        let overloads =  (List.mapi ~f:overload members) @ overloads in
        { annotation with annotation = Type.Callable { callable with overloads } }
    | Some (Type.Primitive name),
      "__getitem__",
      { annotation = Type.Callable ({ kind = Named callable_name; _ } as callable); _ }
      when String.equal (Reference.show callable_name) "typing.Generic.__getitem__" ->
        let implementation =
          let generics =
            Resolution.class_definition resolution (Type.Primitive name)
            >>| create
            >>| generics ~resolution
            |> Option.value ~default:[]
          in
          let parameters =
            let parameter generic =
              Type.Callable.Parameter.Named {
                name = "$";
                annotation = Type.meta generic;
                default = false;
              }
            in
            List.map generics ~f:parameter
          in
          {
            Type.Callable.annotation =
              Type.meta (Type.Parametric { name; parameters = generics });
            parameters = Defined parameters;
          }
        in
        {
          annotation with
          annotation = Type.Callable { callable with implementation; overloads = [] }
        }
    | _ ->
        annotation
  in

  let value = Option.value value ~default:(Node.create Ellipsis ~location) in

  {
    Node.location;
    value = {
      Attribute.name = attribute_name;
      parent = class_annotation;
      annotation;
      value;
      defined;
      class_attribute;
      async;
      initialized;
      property;
      final;
    };

  }


let attribute_table
    ~transitive
    ~class_attributes
    ~include_generated_attributes
    ?instantiated
    ({ Node.value = { Class.name; _ }; _ } as definition)
    ~resolution =
  let original_instantiated = instantiated in
  let instantiated = Option.value instantiated ~default:(annotation definition) in
  let key =
    {
      AttributeCache.transitive;
      class_attributes;
      include_generated_attributes;
      name;
      instantiated;
    }
  in
  match Hashtbl.find AttributeCache.cache key with
  | Some result ->
      result
  | None ->
      let definition_attributes
          ~in_test
          ~instantiated
          ~class_attributes
          ~table
          ({ Node.value = ({ Class.name = parent_name; _ } as definition); _ } as parent) =
        let collect_attributes attribute =
          create_attribute
            attribute
            ~resolution
            ~parent
            ~instantiated
            ~inherited:(not (Reference.equal name parent_name))
            ~default_class_attribute:class_attributes
          |> Attribute.Table.add table
        in
        Statement.Class.attributes ~include_generated_attributes ~in_test definition
        |> fun attribute_map ->
        Identifier.SerializableMap.iter (fun _ data -> collect_attributes data) attribute_map
      in
      let superclass_definitions =
        let superclasses = superclasses ~resolution definition in
        let is_int_enum =
          let bases = bases definition in
          let is_int_enum { Expression.Call.Argument.value; _ } =
            Resolution.parse_annotation resolution value
            |> Type.equal (Type.Primitive "enum.IntEnum")
          in
          List.exists bases ~f:is_int_enum
        in
        if is_int_enum then
          (* TODO(T43355738): We need this hard coding because int adheres to a generic protocol,
             so we incorrectly assume that `IntEnum.__getitem__` corresponds to
             `typing.Generic.__getitem__`. Remove this hard coding once lazy protocols are in. *)
          let not_generic { Node.value = { Class.name; _ }; _ } =
            name <> Reference.create "typing.Generic"
          in
          List.filter superclasses ~f:not_generic
        else
          superclasses
      in
      let in_test =
        List.exists
          (definition :: superclass_definitions)
          ~f:(fun { Node.value; _ } -> Class.is_unit_test value)
      in
      let table = Attribute.Table.create () in
      (* Pass over normal class hierarchy. *)
      let definitions =
        if transitive then
          definition :: superclass_definitions
        else
          [definition]
      in
      List.iter
        definitions
        ~f:(definition_attributes ~in_test ~instantiated ~class_attributes ~table);
      (* Class over meta hierarchy if necessary. *)
      let meta_definitions =
        if class_attributes then
          metaclass ~resolution definition
          |> Resolution.class_definition resolution
          >>| (fun definition -> definition :: superclasses ~resolution definition)
          |> Option.value ~default:[]
        else
          []
      in
      List.iter
        meta_definitions
        ~f:(definition_attributes
              ~in_test
              ~instantiated:(Type.meta instantiated)
              ~class_attributes:false
              ~table);
      let instantiate ~instantiated attribute =
        Attribute.parent attribute
        |> Resolution.class_definition resolution
        >>| (fun target ->
            let constraints =
              constraints
                ~target
                ~instantiated
                ~resolution
                definition
            in
            Attribute.instantiate ~constraints:(Type.Map.find constraints) attribute)
      in
      Option.iter original_instantiated
        ~f:(fun instantiated -> Attribute.Table.filter_map table ~f:(instantiate ~instantiated));
      Hashtbl.set ~key ~data:table AttributeCache.cache;
      table

let attributes
    ?(transitive = false)
    ?(class_attributes = false)
    ?(include_generated_attributes = true)
    ?instantiated
    definition
    ~resolution =
  attribute_table
    ~transitive
    ~class_attributes
    ~include_generated_attributes
    ?instantiated
    definition
    ~resolution
  |>
  Attribute.Table.to_list

let attributes_to_names_and_types =
  let attribute_to_name_and_type attribute =
    let name = Attribute.name attribute in
    match Annotation.annotation (Attribute.annotation attribute) with
    | Type.Callable { kind = Type.Record.Callable.Named _; implementation; overloads; _ } ->
        List.map ~f:Type.Callable.create_from_implementation (implementation :: overloads)
        |> List.map ~f:(fun annotation -> (name, annotation))
    | annotation -> [(name, annotation)]
  in
  List.concat_map ~f:attribute_to_name_and_type

let attribute_fold
    ?(transitive = false)
    ?(class_attributes = false)
    ?(include_generated_attributes = true)
    definition
    ~initial
    ~f
    ~resolution =
  attributes ~transitive ~class_attributes ~include_generated_attributes ~resolution definition
  |> List.fold ~init:initial ~f


let attribute
    ?(transitive = false)
    ?(class_attributes = false)
    ({ Node.location; _ } as definition)
    ~resolution
    ~name
    ~instantiated =
  let table =
    attribute_table
      ~instantiated
      ~transitive
      ~class_attributes
      ~include_generated_attributes:true
      ~resolution
      definition
  in
  match Attribute.Table.lookup_name table name with
  | Some attribute ->
      attribute
  | None ->
      create_attribute
        ~resolution
        ~parent:definition
        ~defined:false
        ~default_class_attribute:class_attributes
        {
          Node.location;
          value = {
            Statement.Attribute.name;
            annotation = None;
            defines = None;
            value = None;
            async = false;
            setter = false;
            property = false;
            primitive = true;
            toplevel = true;
            final = false;
          }
        }


let rec fallback_attribute ~resolution ~name
    ({ Node.value = { Class.name = class_name; _ }; _ } as definition) =
  let compound_backup =
    let name =
      match name with
      | "__iadd__" -> Some "__add__"
      | "__isub__" -> Some "__sub__"
      | "__imul__" -> Some "__mul__"
      | "__imatmul__" -> Some "__matmul__"
      | "__itruediv__" -> Some "__truediv__"
      | "__ifloordiv__" -> Some "__floordiv__"
      | "__imod__" -> Some "__mod__"
      | "__idivmod__" -> Some "__divmod__"
      | "__ipow__" -> Some "__pow__"
      | "__ilshift__" -> Some "__lshift__"
      | "__irshift__" -> Some "__rshift__"
      | "__iand__" -> Some "__and__"
      | "__ixor__" -> Some "__xor__"
      | "__ior__" -> Some "__or__"
      | _ -> None
    in
    match name with
    | Some name ->
        attribute
          definition
          ~class_attributes:false
          ~transitive:true
          ~resolution
          ~name
          ~instantiated:(annotation definition)
        |> Option.some
    | _ ->
        None
  in
  let getitem_backup () =
    let fallback =
      attribute
        definition
        ~class_attributes:true
        ~transitive:true
        ~resolution
        ~name:"__getattr__"
        ~instantiated:(annotation definition)
    in
    if Attribute.defined fallback then
      let annotation =
        fallback
        |> Attribute.annotation
        |> Annotation.annotation
      in
      begin
        match annotation with
        | Type.Callable ({ implementation; _ } as callable) ->
            let location = Attribute.location fallback in
            let arguments =
              let self_argument =
                {
                  Argument.name = None;
                  value = Reference.expression ~convert:true ~location class_name
                }
              in
              let name_argument =
                {
                  Argument.name = None;
                  value = { Node.location; value = Expression.String (StringLiteral.create name) }
                }
              in
              [self_argument; name_argument]
            in
            let implementation =
              match AnnotatedSignature.select ~resolution ~arguments ~callable with
              | AnnotatedSignature.Found { Type.Callable.implementation; _ } ->
                  implementation
              | AnnotatedSignature.NotFound _ ->
                  implementation
            in
            let return_annotation = Type.Callable.Overload.return_annotation implementation in
            Some
              (create_attribute
                 ~resolution
                 ~parent:definition
                 {
                   Node.location;
                   value = {
                     Statement.Attribute.name;
                     annotation = Some (Type.expression ~convert:true return_annotation);
                     defines = None;
                     value = None;
                     async = false;
                     setter = false;
                     property = false;
                     primitive = true;
                     toplevel = true;
                     final = false;
                   };
                 })
        | _ ->
            None
      end
    else
      None
  in
  match compound_backup with
  | Some backup when Attribute.defined backup -> Some backup
  | _ -> getitem_backup ()


let constructor definition ~instantiated ~resolution =
  let return_annotation =
    let class_annotation = annotation definition in
    match class_annotation with
    | Type.Primitive name
    | Type.Parametric { name; _ } ->
        let generics = generics definition ~resolution in
        (* Tuples are special. *)
        if String.equal name "tuple" then
          match generics with
          | [tuple_variable] ->
              Type.Tuple (Type.Unbounded tuple_variable)
          | _ ->
              Type.Tuple (Type.Unbounded Type.Any)
        else
          begin
            let backup = Type.Parametric { name; parameters = generics } in
            match instantiated, generics with
            | _, [] ->
                instantiated
            | Type.Primitive instantiated_name, _ when String.equal instantiated_name name ->
                backup
            | Type.Parametric { parameters; name = instantiated_name }, _
              when String.equal instantiated_name name &&
                   List.length parameters <> List.length generics ->
                backup
            | _ ->
                instantiated
          end
    | _ ->
        instantiated
  in
  let definitions =
    definition :: superclasses ~resolution definition
    |> List.map ~f:(fun definition -> annotation definition)
  in
  let definition_index attribute =
    attribute
    |> Attribute.parent
    |> (fun class_annotation ->
        List.findi definitions ~f:(fun _ annotation -> Type.equal annotation class_annotation))
    >>| fst
    |> Option.value ~default:Int.max_value
  in
  let constructor_signature, constructor_index =
    let attribute =
      attribute
        definition
        ~transitive:true
        ~resolution
        ~name:"__init__"
        ~instantiated
    in
    let signature =
      attribute
      |> Attribute.annotation
      |> Annotation.annotation
    in
    signature, definition_index attribute
  in
  let new_signature, new_index =
    let attribute =
      attribute
        definition
        ~transitive:true
        ~resolution
        ~name:"__new__"
        ~instantiated
    in
    let signature =
      attribute
      |> Attribute.annotation
      |> Annotation.annotation
    in
    signature, definition_index attribute
  in
  let signature =
    if new_index < constructor_index then
      new_signature
    else
      constructor_signature
  in
  match signature with
  | Type.Callable callable ->
      Type.Callable (Type.Callable.with_return_annotation ~annotation:return_annotation callable)
  | _ ->
      signature


let overrides definition ~resolution ~name =
  let find_override parent =
    let potential_override =
      attribute
        ~transitive:false
        ~class_attributes:true
        parent
        ~resolution
        ~name
        ~instantiated:(annotation parent)
    in
    if Attribute.defined potential_override then
      annotation definition
      |> (fun instantiated -> constraints ~target:parent definition ~resolution ~instantiated)
      |> (fun constraints ->
          Attribute.instantiate
            ~constraints:(Type.Map.find constraints)
            potential_override)
      |> Option.some
    else
      None
  in
  superclasses definition ~resolution
  |> List.find_map ~f:find_override


let has_method ?transitive definition ~resolution ~name =
  attribute
    ?transitive
    definition
    ~resolution
    ~name
    ~instantiated:(annotation definition)
  |> Attribute.annotation
  |> Annotation.annotation
  |> Type.is_callable


let inferred_callable_type definition ~resolution =
  let explicit_callables =
    let extract_callable { Method.define = ({ Define.signature = { name; _ }; _ } as define); _ } =
      Option.some_if (Reference.is_suffix ~suffix:(Reference.create "__call__") name) define
      >>| (fun define ->
          Reference.show name,
          Define.is_overloaded_method define,
          Callable.create_overload ~define ~resolution)
    in
    methods definition
    |> List.filter_map ~f:extract_callable
  in
  if List.is_empty explicit_callables then
    None
  else
    let parent = annotation definition in
    let (name, _, _) = List.hd_exn explicit_callables in
    let explicit_callables =
      List.map explicit_callables ~f:(fun (_, is_overload, callable) -> (is_overload, callable))
    in
    let callable = Callable.create ~parent:(Some parent) ~name explicit_callables in
    Some (Type.Callable callable)
