------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2018-2023, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Tags;

with GNAT.Strings;
with GNATCOLL.Traces;
with GNATCOLL.VFS;

with Langkit_Support.Symbols;
with Langkit_Support.Text;

with Laltools.Common;
with Pp.Scanner;
with Utils.Char_Vectors;

with Libadalang.Iterators;
with Libadalang.Sources;

with VSS.Characters.Latin;
with VSS.Strings.Character_Iterators;
with VSS.Strings.Conversions;
with VSS.Strings.Formatters.Integers;
with VSS.Strings.Formatters.Strings;
with VSS.Strings.Templates;

with LSP.Ada_Completions.Filters;
with LSP.Ada_Contexts;
with LSP.Ada_Documentation;
with LSP.Ada_Documents.LAL_Diagnostics;
with LSP.Ada_Handlers.Locations;
with LSP.Ada_Id_Iterators;
with LSP.Enumerations;
with LSP.Formatters.File_Names;
with LSP.Formatters.Texts;
with LSP.Predicates;
with LSP.Structures.LSPAny_Vectors;
with LSP.Utils;

package body LSP.Ada_Documents is
   pragma Warnings (Off);

   package Utils renames Standard.Utils;

   Lal_PP_Output : constant GNATCOLL.Traces.Trace_Handle :=
     GNATCOLL.Traces.Create
       ("ALS.LAL_PP_OUTPUT_ON_FORMATTING", GNATCOLL.Traces.Off);
   --  Logging lalpp output if On

   function To_Completion_Kind (K : LSP.Enumerations.SymbolKind)
     return LSP.Enumerations.CompletionItemKind
   is
     (case K is
        when LSP.Enumerations.A_Function => LSP.Enumerations.A_Function,
        when LSP.Enumerations.Field      => LSP.Enumerations.Field,
        when LSP.Enumerations.Variable   => LSP.Enumerations.Variable,
        when LSP.Enumerations.A_Package  => LSP.Enumerations.Module,
        when LSP.Enumerations.Module     => LSP.Enumerations.Module,
        when LSP.Enumerations.Class      => LSP.Enumerations.Class,
        when LSP.Enumerations.Struct     => LSP.Enumerations.Class,
        when LSP.Enumerations.Number     => LSP.Enumerations.Value,
        when LSP.Enumerations.Enum       => LSP.Enumerations.Enum,
        when LSP.Enumerations.String     => LSP.Enumerations.Value,
        when LSP.Enumerations.A_Constant => LSP.Enumerations.Value,
        when others                      => LSP.Enumerations.Reference);
   --  Convert a SymbolKind to a CompletionItemKind.
   --  TODO: It might be better to have a unified kind, and then convert to
   --  specific kind types, but for the moment this is good enough.

   -------------
   -- Cleanup --
   -------------

   procedure Cleanup (Self : in out Document) is
   begin
      for Source of Self.Diagnostic_Sources loop
         LSP.Diagnostic_Sources.Unchecked_Free (Source);
      end loop;
   end Cleanup;

   -----------------------------
   -- Compute_Completion_Item --
   -----------------------------

   function Compute_Completion_Item
     (Document                 : LSP.Ada_Documents.Document;
      Handler                  : in out LSP.Ada_Handlers.Message_Handler;
      Context                  : LSP.Ada_Contexts.Context;
      Sloc                     : Langkit_Support.Slocs.Source_Location;
      Node                     : Libadalang.Analysis.Ada_Node;
      BD                       : Libadalang.Analysis.Basic_Decl;
      Label                    : VSS.Strings.Virtual_String;
      Use_Snippets             : Boolean;
      Compute_Doc_And_Details  : Boolean;
      Named_Notation_Threshold : Natural;
      Is_Dot_Call              : Boolean;
      Is_Visible               : Boolean;
      Pos                      : Integer;
      Weight                   : Ada_Completions.Completion_Item_Weight_Type;
      Completions_Count        : Natural)
      return LSP.Structures.CompletionItem
   is

      package Weight_Formatters renames VSS.Strings.Formatters.Integers;

      Item           : LSP.Structures.CompletionItem;
      Subp_Spec_Node : Libadalang.Analysis.Base_Subp_Spec;
      Min_Width      : constant Natural := Completions_Count'Image'Length - 1;
      --  The -1 remove the whitespace added by 'Image

      Last_Weight : constant Ada_Completions.Completion_Item_Weight_Type :=
        Ada_Completions.Completion_Item_Weight_Type'Last;

      function Get_Sort_Text
        (Base_Label : VSS.Strings.Virtual_String)
         return VSS.Strings.Virtual_String;
      --  Return a suitable sortText according to the completion item's
      --  visibility and position in the completion list.

      -------------------
      -- Get_Sort_Text --
      -------------------

      function Get_Sort_Text
        (Base_Label : VSS.Strings.Virtual_String)
         return VSS.Strings.Virtual_String
      is
         use VSS.Strings;
      begin
         return Sort_Text : VSS.Strings.Virtual_String do

            Sort_Text := VSS.Strings.Templates.Format
              ("{:02}&{:05}{}",
               Weight_Formatters.Image (Last_Weight - Weight),
               Weight_Formatters.Image (Pos),
               VSS.Strings.Formatters.Strings.Image (Base_Label));

            if not Is_Visible then
               Sort_Text.Prepend ('~');
            end if;
         end return;
      end Get_Sort_Text;

   begin
      Item.label := Label;
      Item.kind := (True, To_Completion_Kind (LSP.Utils.Get_Decl_Kind (BD)));

      if not Is_Visible then
         Item.insertText := Label;
         Item.label.Append (" (invisible)");
         Item.filterText := Label;
      end if;

      Item.sortText := Get_Sort_Text (Label);

      Set_Completion_Item_Documentation
        (Handler                 => Handler,
         Context                 => Context,
         BD                      => BD,
         Item                    => Item,
         Compute_Doc_And_Details => Compute_Doc_And_Details);

      --  Return immediately if we should not use snippets (e.g: completion for
      --  invisible symbols).
      if not Use_Snippets then
         return Item;
      end if;

      --  Check if we are dealing with a subprogram and return a completion
      --  snippet that lists all the formal parameters if it's the case.

      Subp_Spec_Node := BD.P_Subp_Spec_Or_Null;

      if Subp_Spec_Node.Is_Null then
         return Item;
      end if;

      declare
         Insert_Text : VSS.Strings.Virtual_String := Label;
         All_Params  : constant Libadalang.Analysis.Param_Spec_Array :=
           Subp_Spec_Node.P_Params;

         Params      : constant Libadalang.Analysis.Param_Spec_Array :=
           (if Is_Dot_Call then
               All_Params (All_Params'First + 1 .. All_Params'Last)
            else
               All_Params);
         --  Remove the first formal parameter from the list when the dotted
         --  notation is used.

         Idx                : Positive := 1;
         Nb_Params          : Natural := 0;
         Use_Named_Notation : Boolean := False;
      begin

         --  Create a completion snippet if the subprogram expects some
         --  parameters.

         if Params'Length /= 0 then
            Item.insertTextFormat :=
              (Is_Set => True,
               Value  => LSP.Enumerations.Snippet);

            Insert_Text.Append (" (");

            --  Compute number of params to know if named notation should be
            --  used.

            for Param of Params loop
               Nb_Params := Nb_Params + Param.F_Ids.Children_Count;
            end loop;

            Use_Named_Notation := Named_Notation_Threshold > 0
              and then Nb_Params >= Named_Notation_Threshold;

            for Param of Params loop
               for Id of Param.F_Ids loop
                  declare
                     Mode      : constant Langkit_Support.Text.Text_Type :=
                       Param.F_Mode.Text;
                     Mode_Text : constant Langkit_Support.Text.Text_Type :=
                       (if Mode /= "" then Mode & " " else "");

                     Named_Template      : constant
                       VSS.Strings.Templates.Virtual_String_Template :=
                         "{} => ${{{}:{}{}}, ";
                     Positional_Template : constant
                       VSS.Strings.Templates.Virtual_String_Template :=
                         "${{{}:{} : {}{}}, ";
                     Text                : VSS.Strings.Virtual_String;

                  begin
                     if Use_Named_Notation then
                        Text :=
                          Named_Template.Format
                            (LSP.Formatters.Texts.Image (Id.Text),
                             VSS.Strings.Formatters.Integers.Image (Idx),
                             LSP.Formatters.Texts.Image (Mode_Text),
                             LSP.Formatters.Texts.Image
                               (Param.F_Type_Expr.Text));

                     else
                        Text :=
                          Positional_Template.Format
                            (VSS.Strings.Formatters.Integers.Image (Idx),
                             LSP.Formatters.Texts.Image (Id.Text),
                             LSP.Formatters.Texts.Image (Mode_Text),
                             LSP.Formatters.Texts.Image
                               (Param.F_Type_Expr.Text));
                     end if;

                     Insert_Text.Append (Text);
                     Idx := Idx + 1;
                  end;
               end loop;
            end loop;

            --  Remove the ", " substring that has been appended in the last
            --  loop iteration.

            declare
               First   : constant
                 VSS.Strings.Character_Iterators.Character_Iterator :=
                   Insert_Text.At_First_Character;
               Last    : VSS.Strings.Character_Iterators.Character_Iterator :=
                 Insert_Text.At_Last_Character;
               Success : Boolean with Unreferenced;

            begin
               Success := Last.Backward;
               Success := Last.Backward;

               Insert_Text := Insert_Text.Slice (First, Last);
               --  ??? May be replaced by "Head" like procedure when it will be
               --  implemented.
            end;

            --  Insert '$0' (i.e: the final tab stop) at the end.
            Insert_Text.Append (")$0");

            Item.insertText := Insert_Text;
         end if;
      end;

      return Item;
   end Compute_Completion_Item;

   -------------------------
   -- Find_All_References --
   -------------------------

   procedure Find_All_References
     (Self       : Document; Context : LSP.Ada_Contexts.Context;
      Definition : Libadalang.Analysis.Defining_Name;
      Callback   : not null access procedure
        (Base_Id : Libadalang.Analysis.Base_Id;
         Kind    : Libadalang.Common.Ref_Result_Kind; Cancel : in out Boolean))
   is
      Units : constant Libadalang.Analysis.Analysis_Unit_Array :=
        (1 =>  LSP.Ada_Documents.Unit (Self    => Self,
                                       Context => Context));
   begin
      LSP.Ada_Id_Iterators.Find_All_References (Definition, Units, Callback);
   exception
      when E : Libadalang.Common.Property_Error =>
         Self.Tracer.Trace_Exception (E, "in Find_All_References");
   end Find_All_References;

   ----------------
   -- Formatting --
   ----------------

   function Formatting
     (Self     : Document;
      Context  : LSP.Ada_Contexts.Context;
      Span     : LSP.Structures.A_Range;
      Cmd      : Pp.Command_Lines.Cmd_Line;
      Edit     : out LSP.Structures.TextEdit_Vector;
      Messages : out VSS.String_Vectors.Virtual_String_Vector) return Boolean
   is
      use type Libadalang.Slocs.Source_Location_Range;
      use type LSP.Structures.A_Range;

      Sloc        : constant Libadalang.Slocs.Source_Location_Range :=
        (if Span = LSP.Constants.Empty
         then Libadalang.Slocs.No_Source_Location_Range
         else Self.To_Source_Location_Range (Span));
      Input       : Utils.Char_Vectors.Char_Vector;
      Output      : Utils.Char_Vectors.Char_Vector;
      Out_Span    : LSP.Structures.A_Range;
      PP_Messages : Pp.Scanner.Source_Message_Vector;
      Out_Sloc    : Libadalang.Slocs.Source_Location_Range;
      S           : GNAT.Strings.String_Access;

   begin
      if Span /= LSP.Constants.Empty then
         --  Align Span to line bounds

         if Span.start.character /= 0 then
            return Self.Formatting
              (Context  => Context,
               Span     => ((Span.start.line, 0), Span.an_end),
               Cmd      => Cmd,
               Edit     => Edit,
               Messages => Messages);

         elsif Span.an_end.character /= 0 then
            return Self.Formatting
              (Context  => Context,
               Span     => (Span.start, (Span.an_end.line + 1, 0)),
               Cmd      => Cmd,
               Edit     => Edit,
               Messages => Messages);
         end if;
      end if;

      S := new String'(VSS.Strings.Conversions.To_UTF_8_String (Self.Text));
      Input.Append (S.all);
      GNAT.Strings.Free (S);

      LSP.Utils.Format_Vector
        (Cmd       => Cmd,
         Input     => Input,
         Node      => Self.Unit (Context).Root,
         In_Sloc   => Sloc,
         Output    => Output,
         Out_Sloc  => Out_Sloc,
         Messages  => PP_Messages);

      --  Properly format the messages received from gnatpp, using the
      --  the GNAT standard way for messages (i.e: <filename>:<sloc>: <msg>)

      if not PP_Messages.Is_Empty then
         declare
            File     : constant GNATCOLL.VFS.Virtual_File :=
              Context.URI_To_File (Self.URI);
            Template : constant VSS.Strings.Templates.Virtual_String_Template :=
              "{}:{}:{}: {}";

         begin
            for Error of PP_Messages loop
               Messages.Append
                 (Template.Format
                    (LSP.Formatters.File_Names.Image (File),
                     VSS.Strings.Formatters.Integers.Image (Error.Sloc.Line),
                     VSS.Strings.Formatters.Integers.Image (Error.Sloc.Col),
                     VSS.Strings.Formatters.Strings.Image
                       (VSS.Strings.Conversions.To_Virtual_String
                            (String
                                 (Utils.Char_Vectors.Char_Vectors.To_Array
                                    (Error.Text))))));
            end loop;

            return False;
         end;
      end if;

      S := new String'(Output.To_Array);

      if Lal_PP_Output.Is_Active then
         Lal_PP_Output.Trace (S.all);
      end if;

      if Span = LSP.Constants.Empty then
         --  diff for the whole document

         Self.Diff
           (VSS.Strings.Conversions.To_Virtual_String (S.all),
            Edit => Edit);

      elsif Out_Sloc = Libadalang.Slocs.No_Source_Location_Range then
         --  Range formating fails. Do nothing, skip formating altogether

         null;

      else
         --  diff for a part of the document

         Out_Span := Self.To_A_Range (Out_Sloc);

         --  Use line diff if the range is too wide

         if Span.an_end.line - Span.start.line > 5 then
            Self.Diff
              (VSS.Strings.Conversions.To_Virtual_String (S.all),
               Span,
               Out_Span,
               Edit);

         else
            declare
               Formatted : constant VSS.Strings.Virtual_String :=
                 VSS.Strings.Conversions.To_Virtual_String (S.all);
               Slice     : VSS.Strings.Virtual_String;

            begin
               LSP.Utils.Span_To_Slice (Formatted, Out_Span, Slice);

               Self.Diff_Symbols (Span, Slice, Edit);
            end;
         end if;
      end if;

      GNAT.Strings.Free (S);

      return True;

   exception
      when E : others =>
         Lal_PP_Output.Trace (E);
         GNAT.Strings.Free (S);

         return False;
   end Formatting;

   --------------------
   -- Get_Any_Symbol --
   --------------------

   procedure Get_Any_Symbol
     (Self        : in out Document; Context : LSP.Ada_Contexts.Context;
      Pattern     : LSP.Search.Search_Pattern'Class;
      Limit       : Ada.Containers.Count_Type;
      Only_Public : Boolean;
      Canceled    : access function return Boolean;
      Result      : in out LSP.Ada_Completions.Completion_Maps.Map)
   is

      procedure Refresh_Symbol_Cache;
      --  Find intresting definings names in the document and put them
      --  into Self.Symbol_Cache

      procedure Insert
        (Item : Name_Information;
         Name : Libadalang.Analysis.Defining_Name);
      --  Populate Result with the name information if Result doesn't have
      --  the Name already

      function Get_Defining_Name
        (Loc : Langkit_Support.Slocs.Source_Location)
         return Libadalang.Analysis.Defining_Name;

      -----------------------
      -- Get_Defining_Name --
      -----------------------

      function Get_Defining_Name
        (Loc : Langkit_Support.Slocs.Source_Location)
         return Libadalang.Analysis.Defining_Name
      is
         Unit : constant Libadalang.Analysis.Analysis_Unit :=
             Self.Unit (Context);

         Name : constant Libadalang.Analysis.Name :=
           Laltools.Common.Get_Node_As_Name (Unit.Root.Lookup (Loc));
      begin
         return Laltools.Common.Get_Name_As_Defining (Name);
      end Get_Defining_Name;

      ------------
      -- Insert --
      ------------

      procedure Insert
        (Item : Name_Information;
         Name : Libadalang.Analysis.Defining_Name) is
      begin
         if not Result.Contains (Name) and then
           (not Only_Public or else Item.Is_Public)
         then
            Result.Insert
              (Name,
               (Is_Dot_Call  => False,
                Is_Visible   => False,
                Use_Snippets => False,
                Pos          => <>,
                Weight       => <>));
         end if;
      end Insert;

      --------------------------
      -- Refresh_Symbol_Cache --
      --------------------------

      procedure Refresh_Symbol_Cache is
         use Langkit_Support.Symbols;
         use Libadalang.Common;
         use Libadalang.Iterators;

         Node : Libadalang.Analysis.Ada_Node;

         Global_Visible : constant Libadalang.Iterators.Ada_Node_Predicate :=
           LSP.Predicates.Is_Global_Visible;

         Restricted_Kind : constant Libadalang.Iterators.Ada_Node_Predicate :=
           LSP.Predicates.Is_Restricted_Kind;

         --  Find all definings names excluding private parts and bodies
         It : Libadalang.Iterators.Traverse_Iterator'Class :=
           Libadalang.Iterators.Find
             (Self.Unit (Context).Root,
              Libadalang.Iterators.Kind_Is (Ada_Defining_Name)
                and not Restricted_Kind);

      begin
         while It.Next (Node) loop
            declare
               Token     : constant Token_Reference := Node.Token_End;
               Text      : constant Langkit_Support.Text.Text_Type :=
                 Libadalang.Common.Text (Token);
               Canonical : constant Symbolization_Result :=
                 Libadalang.Sources.Canonicalize (Text);
               Cursor    : Symbol_Maps.Cursor;
               Inserted  : Boolean;

            begin
               if Canonical.Success then
                  Self.Symbol_Cache.Insert
                    (VSS.Strings.To_Virtual_String (Canonical.Symbol),
                     Name_Vectors.Empty_Vector,
                     Cursor,
                     Inserted);

                  Self.Symbol_Cache (Cursor).Append
                    (Name_Information'
                       (Langkit_Support.Slocs.Start_Sloc (Node.Sloc_Range),
                        Global_Visible.Unchecked_Get.Evaluate (Node)));
               end if;
            end;
         end loop;
      end Refresh_Symbol_Cache;

      Cursor      : Symbol_Maps.Cursor;

      use type LSP.Search.Search_Kind;

      --  In "Celling" mode we scan only range of cache where a key prefix
      --  matches lowercased pattern as is.
      Use_Celling : constant Boolean :=
        not Pattern.Get_Negate
        and then ((Pattern.Get_Kind = LSP.Enumerations.Full_Text
                   and then Pattern.Get_Whole_Word)
                  or else Pattern.Get_Kind = LSP.Enumerations.Start_Word_Text);

   begin
      if Self.Refresh_Symbol_Cache then
         Refresh_Symbol_Cache;
         Self.Refresh_Symbol_Cache := False;
      end if;

      if Use_Celling then
         Cursor := Self.Symbol_Cache.Ceiling (Pattern.Get_Canonical_Pattern);
      else
         Cursor := Self.Symbol_Cache.First;
      end if;

      while Symbol_Maps.Has_Element (Cursor) loop

         if Use_Celling
           and then not Pattern.Match (Symbol_Maps.Key (Cursor))
         then
            --  We use "Celling mode" and key stops matching,
            --  Symbol_Cache is ordered so we will not find any
            --  matches more

            exit when Use_Celling or else Canceled.all;

         else

            for Item of Self.Symbol_Cache (Cursor) loop
               declare
                  Defining_Name : constant Libadalang.Analysis.Defining_Name :=
                    Get_Defining_Name (Item.Loc);
               begin
                  --  Match each element individually in case of sensitive
                  --  search or non-celling mode
                  if not Defining_Name.Is_Null
                    and then
                      ((Use_Celling
                        and then not Pattern.Get_Case_Sensitive)
                       or else Pattern.Match
                         (VSS.Strings.To_Virtual_String
                            (Defining_Name.As_Ada_Node.Text)))
                  then
                     Insert (Item, Defining_Name);
                  end if;

                  exit when Canceled.all;

               end;
            end loop;

         end if;

         Symbol_Maps.Next (Cursor);
      end loop;
   end Get_Any_Symbol;

   -------------------------
   -- Get_Completion_Node --
   -------------------------

   procedure Get_Completion_Node
     (Self     : Document;
      Context  : LSP.Ada_Contexts.Context;
      Position : LSP.Structures.Position;
      Sloc     : out Langkit_Support.Slocs.Source_Location;
      Token    : out Libadalang.Common.Token_Reference;
      Node     : out Libadalang.Analysis.Ada_Node)
   is
      use Libadalang.Common;

      function Completion_Token
        (Sloc  : Langkit_Support.Slocs.Source_Location)
         return Libadalang.Common.Token_Reference;
      --  Get token under completion for given cursor position.
      --  If cursor at the first symbol of a token return previous token:
      --  XXX___
      --     ^ cursor just after a token mean user is completion XXX token.

      ----------------------
      -- Completion_Token --
      ----------------------

      function Completion_Token
        (Sloc  : Langkit_Support.Slocs.Source_Location)
         return Libadalang.Common.Token_Reference
      is
         use type Langkit_Support.Slocs.Source_Location;

         Token : constant Libadalang.Common.Token_Reference :=
           Self.Get_Token_At (Context, Position);

         Prev  : constant Libadalang.Common.Token_Reference :=
           (if Token = Libadalang.Common.No_Token
            then Token
            else Libadalang.Common.Previous (Token));

      begin
         if Libadalang.Common.No_Token not in Token | Prev then
            declare
               Data  : constant Libadalang.Common.Token_Data_Type :=
                 Libadalang.Common.Data (Token);

               Start : constant Langkit_Support.Slocs.Source_Location :=
                 Langkit_Support.Slocs.Start_Sloc
                   (Libadalang.Common.Sloc_Range (Data));
            begin
               if Start = Sloc then
                  return Prev;
               end if;
            end;
         end if;

         return Token;
      end Completion_Token;
   begin
      Sloc := Self.To_Source_Location (Position);
      Token := Completion_Token (Sloc);
      declare
         From : constant Langkit_Support.Slocs.Source_Location :=
           Langkit_Support.Slocs.Start_Sloc
             (Libadalang.Common.Sloc_Range
                (Libadalang.Common.Data (Token)));

         Root : constant Libadalang.Analysis.Ada_Node :=
           Self.Unit (Context).Root;
      begin
         Node := (if Root.Is_Null then Root else Root.Lookup (From));
      end;
   end Get_Completion_Node;

   ------------------------
   -- Get_Completions_At --
   ------------------------

   procedure Get_Completions_At
     (Self      : Document;
      Providers : LSP.Ada_Completions.Completion_Provider_List;
      Context   : LSP.Ada_Contexts.Context;
      Sloc      : Langkit_Support.Slocs.Source_Location;
      Token     : Libadalang.Common.Token_Reference;
      Node      : Libadalang.Analysis.Ada_Node;
      Names     : out Ada_Completions.Completion_Maps.Map;
      Result    : out LSP.Structures.CompletionList)
   is
      Parent : constant Libadalang.Analysis.Ada_Node :=
        (if Node.Is_Null then Node else Node.Parent);

      Filter : LSP.Ada_Completions.Filters.Filter;
   begin
      if not Parent.Is_Null
        and then (Parent.Kind not in
          Libadalang.Common.Ada_Dotted_Name | Libadalang.Common.Ada_End_Name
          and then Node.Kind in Libadalang.Common.Ada_String_Literal_Range)
      then
         --  Do nothing when inside a string
         return;
      end if;

      Self.Tracer.Trace
        ("Getting completions, Pos = ("
         & Sloc.Line'Image & ", " & Sloc.Column'Image & ") Node = "
         & Libadalang.Analysis.Image (Node));

      Filter.Initialize (Token, Node);

      for Provider of Providers loop
         begin
            Provider.Propose_Completion
              (Sloc   => Sloc,
               Token  => Token,
               Node   => Node,
               Filter => Filter,
               Names  => Names,
               Result => Result);

         exception
            when E : Libadalang.Common.Property_Error =>
               Self.Tracer.Trace_Exception
                 (E,
                  "LAL EXCEPTION occurred with following completion provider");
               Self.Tracer.Trace (Ada.Tags.Expanded_Name (Provider'Tag));
         end;
      end loop;

      Self.Tracer.Trace
        ("Number of filtered completions : " & Names.Length'Image);
   end Get_Completions_At;

   ----------------
   -- Get_Errors --
   ----------------

   procedure Get_Errors
     (Self    : in out Document;
      Context : LSP.Ada_Contexts.Context;
      Changed : out Boolean;
      Errors  : out LSP.Structures.Diagnostic_Vector;
      Force   : Boolean := False)
   is
   begin
      Errors.Clear;
      Changed := (for some Source of Self.Diagnostic_Sources =>
                    Source.Has_New_Diagnostic (Context));

      if Changed or else Force then
         for Source of Self.Diagnostic_Sources loop
            Source.Get_Diagnostic (Context, Errors);
         end loop;
      end if;
   end Get_Errors;

   ------------------------
   -- Get_Folding_Blocks --
   ------------------------

   procedure Get_Folding_Blocks
     (Self       : Document;
      Context    : LSP.Ada_Contexts.Context;
      Lines_Only : Boolean;
      Comments   : Boolean;
      Canceled   : access function return Boolean;
      Result     : out LSP.Structures.FoldingRange_Vector)
   is
      use Libadalang.Common;
      use Libadalang.Analysis;

      Location     : LSP.Structures.Location;
      foldingRange : LSP.Structures.FoldingRange;
      Have_With    : Boolean := False;

      function Parse (Node : Ada_Node'Class) return Visit_Status;
      --  Includes Node location to the result if the node has "proper" kind

      procedure Store_Span (Span : LSP.Structures.A_Range);
      --  Include Span to the result .

      -----------
      -- Parse --
      -----------

      function Parse (Node : Ada_Node'Class) return Visit_Status
      is

         procedure Store_With_Block;
         --  Store folding for with/use clauses as one folding block

         ----------------------
         -- Store_With_Block --
         ----------------------

         procedure Store_With_Block is
         begin
            if not Have_With then
               return;
            end if;

            if foldingRange.startLine /= foldingRange.endLine then
               Result.Append (foldingRange);
            end if;

            Have_With := False;
         end Store_With_Block;

         Result : Visit_Status := Into;
      begin
         if Canceled.all then
            return Stop;
         end if;

--        Cat_Namespace,
--        Cat_Constructor,
--        Cat_Destructor,
--        Cat_Structure,
--        Cat_Case_Inside_Record,
--        Cat_Union,
--        Cat_Custom

         case Node.Kind is
            when Ada_Package_Decl |
                 Ada_Generic_Formal_Package |
                 Ada_Package_Body |
--        Cat_Package

                 Ada_Type_Decl |

                 Ada_Classwide_Type_Decl |
--        Cat_Class

                 Ada_Protected_Type_Decl |
--        Cat_Protected

                 Ada_Task_Type_Decl |
                 Ada_Single_Task_Type_Decl |
--        Cat_Task

                 Ada_Subp_Decl |
                 Ada_Subp_Body |
                 Ada_Generic_Formal_Subp_Decl |
                 Ada_Abstract_Subp_Decl |
                 Ada_Abstract_Formal_Subp_Decl |
                 Ada_Concrete_Formal_Subp_Decl |
                 Ada_Generic_Subp_Internal |
                 Ada_Null_Subp_Decl |
                 Ada_Subp_Renaming_Decl |
                 Ada_Subp_Body_Stub |
                 Ada_Generic_Subp_Decl |
                 Ada_Generic_Subp_Instantiation |
                 Ada_Generic_Subp_Renaming_Decl |
                 Ada_Subp_Kind_Function |
                 Ada_Subp_Kind_Procedure |
                 Ada_Access_To_Subp_Def |
--        Cat_Procedure
--        Cat_Function
--        Cat_Method

                 Ada_Case_Stmt |
--        Cat_Case_Statement

                 Ada_If_Stmt |
--        Cat_If_Statement

                 Ada_For_Loop_Stmt |
                 Ada_While_Loop_Stmt |
--        Cat_Loop_Statement

                 Ada_Begin_Block |
                 Ada_Decl_Block |
--        Cat_Declare_Block
--        Cat_Simple_Block

--                 Ada_Return_Stmt |
--                 Ada_Extended_Return_Stmt |
                 Ada_Extended_Return_Stmt_Object_Decl |
--        Cat_Return_Block

                 Ada_Select_Stmt |
--        Cat_Select_Statement

                 Ada_Entry_Body |
--        Cat_Entry

                 Ada_Exception_Handler |
--        Cat_Exception_Handler

                 Ada_Pragma_Node_List |
                 Ada_Pragma_Argument_Assoc |
                 Ada_Pragma_Node |
--        Cat_Pragma

                 Ada_Aspect_Spec =>
--        Cat_Aspect

               Store_With_Block;

               foldingRange.kind :=
                 (Is_Set => True, Value => LSP.Enumerations.Region);

               Location := Self.To_LSP_Location (Node.Sloc_Range);
               Store_Span (Location.a_range);

            when Ada_With_Clause |
                 Ada_Use_Package_Clause |
                 Ada_Use_Type_Clause =>

               Location := Self.To_LSP_Location (Node.Sloc_Range);

               if not Have_With then
                  Have_With := True;

                  foldingRange.kind :=
                    (Is_Set => True, Value => LSP.Enumerations.Imports);

                  foldingRange.startLine := Location.a_range.start.line;
               end if;

               foldingRange.endLine := Location.a_range.an_end.line;

               --  Do not step into with/use clause
               Result := Over;

            when others =>
               Store_With_Block;
         end case;

         return Result;
      end Parse;

      ----------------
      -- Store_Span --
      ----------------

      procedure Store_Span (Span : LSP.Structures.A_Range) is
      begin
         if not Lines_Only
           or else Span.start.line /= Span.an_end.line
         then
            foldingRange.startLine := Span.start.line;
            foldingRange.endLine   := Span.an_end.line;

            if not Lines_Only then
               foldingRange.startCharacter :=
                 (Is_Set => True,
                  Value  => Span.start.character);

               foldingRange.startCharacter :=
                 (Is_Set => True,
                  Value  => Span.an_end.character);
            end if;

            Result.Append (foldingRange);
         end if;
      end Store_Span;

      Token : Token_Reference;
      Span  : LSP.Structures.A_Range;

   begin
      Traverse (Self.Unit (Context).Root, Parse'Access);

      if not Comments then
         --  do not process comments
         return;
      end if;

      --  Looking for comments
      foldingRange.kind := (Is_Set => False);
      Token             := First_Token (Self.Unit (Context));

      while Token /= No_Token
        and then not Canceled.all
      loop
         case Kind (Data (Token)) is
            when Ada_Comment =>
               if not foldingRange.kind.Is_Set then
                  foldingRange.kind :=
                    (Is_Set => True, Value => LSP.Enumerations.Comment);
                  Span := Self.To_A_Range (Sloc_Range (Data (Token)));
               else
                  Span.an_end :=
                    Self.To_A_Range (Sloc_Range (Data (Token))).an_end;
               end if;

            when Ada_Whitespace =>
               null;

            when others =>
               if foldingRange.kind.Is_Set then
                  Store_Span (Span);
                  foldingRange.kind := (Is_Set => False);
               end if;
         end case;

         Token := Next (Token);
      end loop;
   end Get_Folding_Blocks;

   ---------------------------
   -- Get_Formatting_Region --
   ---------------------------

   function Get_Formatting_Region
     (Self     : Document;
      Context  : LSP.Ada_Contexts.Context;
      Position : LSP.Structures.Position)
      return Laltools.Partial_GNATPP.Formatting_Region_Type
   is (Laltools.Partial_GNATPP.Get_Formatting_Region
        (Unit        => Self.Unit (Context),
         Input_Range =>
            Self.To_Source_Location_Range ((Position, Position))));

   ---------------------
   -- Get_Indentation --
   ---------------------

   function Get_Indentation
     (Self    : Document;
      Context : LSP.Ada_Contexts.Context;
      Line    : Positive)
      return VSS.Strings.Character_Count
   is
     (VSS.Strings.Character_Count
        (Laltools.Partial_GNATPP.Estimate_Indentation
             (Self.Unit (Context),
              Self.To_Source_Location ((Line, 1)).Line)));

   -----------------
   -- Get_Node_At --
   -----------------

   function Get_Node_At
     (Self     : Document;
      Context  : LSP.Ada_Contexts.Context;
      Position : LSP.Structures.Position) return Libadalang.Analysis.Ada_Node
   is
      Unit : constant Libadalang.Analysis.Analysis_Unit := Self.Unit (Context);
   begin
      return (if Unit.Root.Is_Null then Libadalang.Analysis.No_Ada_Node
              else Unit.Root.Lookup (Self.To_Source_Location (Position)));
   end Get_Node_At;

   --------------------------
   -- Get_Symbol_Hierarchy --
   --------------------------

   procedure Get_Symbol_Hierarchy
     (Self     :     Document; Context : LSP.Ada_Contexts.Context;
      Pattern  :     LSP.Search.Search_Pattern'Class;
      Canceled :     access function return Boolean;
      Result   : out LSP.Structures.DocumentSymbol_Vector)
   is
   begin
      pragma Compile_Time_Warning
        (Standard.True, "Get_Symbol_Hierarchy unimplemented");
      raise Program_Error with "Unimplemented procedure Get_Symbol_Hierarchy";
   end Get_Symbol_Hierarchy;

   -----------------
   -- Get_Symbols --
   -----------------

   procedure Get_Symbols
     (Self     :     Document; Context : LSP.Ada_Contexts.Context;
      Pattern  :     LSP.Search.Search_Pattern'Class;
      Canceled :     access function return Boolean;
      Result   : out LSP.Structures.DocumentSymbol_Vector)
   is
   begin
      pragma Compile_Time_Warning (Standard.True, "Get_Symbols unimplemented");
      raise Program_Error with "Unimplemented procedure Get_Symbols";
   end Get_Symbols;

   ------------------
   -- Get_Token_At --
   ------------------

   function Get_Token_At
     (Self     : Document'Class; Context : LSP.Ada_Contexts.Context;
      Position : LSP.Structures.Position)
      return Libadalang.Common.Token_Reference
   is
     (Self.Unit (Context).Lookup_Token (Self.To_Source_Location (Position)));

   ----------------
   -- Get_Tokens --
   ----------------

   function Get_Tokens
     (Self        : Document'Class; Context : LSP.Ada_Contexts.Context;
      Highlighter : LSP.Ada_Highlighters.Ada_Highlighter;
      Span        : LSP.Structures.A_Range := ((1, 1), (0, 0)))
      return LSP.Structures.Natural_Vector
   is
      (Highlighter.Get_Tokens (Self.Unit (Context), Context.Tracer.all, Span));

   -----------------
   -- Get_Word_At --
   -----------------

   function Get_Word_At
     (Self     : Document;
      Context  : LSP.Ada_Contexts.Context;
      Position : LSP.Structures.Position) return VSS.Strings.Virtual_String
   is
      use Langkit_Support.Slocs;
      use all type Libadalang.Common.Token_Kind;

      Result : VSS.Strings.Virtual_String;

      Unit : constant Libadalang.Analysis.Analysis_Unit :=
        Self.Unit (Context);

      Origin : constant Source_Location := Self.To_Source_Location (Position);
      Where : constant Source_Location := (Origin.Line, Origin.Column - 1);
      --  Compute the position we want for completion, which is one character
      --  before the cursor.

      Token : constant Libadalang.Common.Token_Reference :=
        Unit.Lookup_Token (Where);

      Data : constant Libadalang.Common.Token_Data_Type :=
        Libadalang.Common.Data (Token);

      Kind : constant Libadalang.Common.Token_Kind :=
        Libadalang.Common.Kind (Data);

      Text : constant Langkit_Support.Text.Text_Type :=
        Libadalang.Common.Text (Token);

      Sloc : constant Source_Location_Range :=
        Libadalang.Common.Sloc_Range (Data);

      Span : constant Integer :=
        Natural (Where.Column) - Natural (Sloc.Start_Column);

   begin
      if Kind in Ada_Identifier .. Ada_Xor
        and then Compare (Sloc, Where) = Inside
      then
         Result := VSS.Strings.To_Virtual_String
           (Text (Text'First .. Text'First + Span));
      end if;

      return Result;
   end Get_Word_At;

   ---------------------
   -- Has_Diagnostics --
   ---------------------

   function Has_Diagnostics
     (Self : Document; Context : LSP.Ada_Contexts.Context) return Boolean
   is
      (Self.Unit (Context).Has_Diagnostics);

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Self       : in out Document;
      URI        : LSP.Structures.DocumentUri;
      Text       : VSS.Strings.Virtual_String;
      Diagnostic : LSP.Diagnostic_Sources.Diagnostic_Source_Access) is
   begin
      LSP.Text_Documents.Constructors.Initialize (Self, URI, Text);

      Self.Refresh_Symbol_Cache   := True;
      Self.Diagnostic_Sources (1) := new
        LSP.Ada_Documents.LAL_Diagnostics.Diagnostic_Source
          (Self'Unchecked_Access);
      Self.Diagnostic_Sources (2)  := Diagnostic;
   end Initialize;

   ----------------------
   -- Range_Formatting --
   ----------------------

   function Range_Formatting
     (Self       : Document;
      Context    : LSP.Ada_Contexts.Context;
      Span       : LSP.Structures.A_Range;
      PP_Options : Pp.Command_Lines.Cmd_Line;
      Edit       : out LSP.Structures.TextEdit_Vector;
      Messages   : out VSS.String_Vectors.Virtual_String_Vector) return Boolean
   is
      use Libadalang.Analysis;
      use Langkit_Support.Slocs;
      use Laltools.Partial_GNATPP;
      use LSP.Structures;
      use Utils.Char_Vectors;
      use Utils.Char_Vectors.Char_Vectors;

      procedure Append_PP_Messages
        (PP_Messages : Pp.Scanner.Source_Message_Vector);
      --  Append any message of PP_Messages to Messages properly formatting
      --  them using the GNAT standard way for messages
      --  (i.e: <filename>:<sloc>: <msg>)

      ------------------------
      -- Append_PP_Messages --
      ------------------------

      procedure Append_PP_Messages
        (PP_Messages : Pp.Scanner.Source_Message_Vector) is
      begin
         for Message of PP_Messages loop
            declare
               Error : LSP.Structures.DocumentUri := Self.URI;
            begin
               Error.Append (":");
               Error.Append
                 (VSS.Strings.Conversions.To_Virtual_String
                    (Pp.Scanner.Sloc_Image (Message.Sloc)));
               Error.Append (": ");
               Error.Append
                 (VSS.Strings.Conversions.To_Virtual_String
                    (String (To_Array (Message.Text))));
               Messages.Append (Error);
            end;
         end loop;
      end Append_PP_Messages;

   begin
      Self.Tracer.Trace ("On Range_Formatting");

      Self.Tracer.Trace ("Format_Selection");
      declare
         Unit                    : constant Analysis_Unit :=
           Self.Unit (Context);
         Input_Selection_Range   : constant Source_Location_Range :=
           (if Span = LSP.Text_Documents.Empty_Range
            then No_Source_Location_Range
            else Self.To_Source_Location_Range (Span));
         Partial_Formatting_Edit :
           constant Laltools.Partial_GNATPP.Partial_Formatting_Edit :=
             Format_Selection (Unit, Input_Selection_Range, PP_Options);

      begin
         if not Partial_Formatting_Edit.Diagnostics.Is_Empty then
            Append_PP_Messages (Partial_Formatting_Edit.Diagnostics);
            Self.Tracer.Trace
              ("Non empty diagnostics from GNATPP - "
               & "not continuing with Range_Formatting");
            return False;
         end if;

         Self.Tracer.Trace ("Computing Range_Formatting Text_Edits");
         Edit.Clear;
         declare
            Edit_Span : constant LSP.Structures.A_Range :=
              Self.To_A_Range (Partial_Formatting_Edit.Edit.Location);
            Edit_Text : constant VSS.Strings.Virtual_String :=
              VSS.Strings.Conversions.To_Virtual_String
                (Partial_Formatting_Edit.Edit.Text);

         begin
            Edit.Append (TextEdit'(Edit_Span, Edit_Text));
         end;

         return True;
      end;

   exception
      when E : others =>
         Self.Tracer.Trace_Exception (E, "in Range_Formatting");
         return False;
   end Range_Formatting;

   ------------------------
   -- Reset_Symbol_Cache --
   ------------------------

   procedure Reset_Symbol_Cache (Self : in out Document'Class) is
   begin
      for Item of Self.Symbol_Cache loop
         --  We clear defining name vectors, but keep symbol map in hope, that
         --  we will reuse the same elements after reindexing in
         --  Refresh_Symbol_Cache call, so we avoid memory reallocation.
         Item.Clear;
      end loop;

      Self.Refresh_Symbol_Cache := True;
   end Reset_Symbol_Cache;

   ---------------------------------------
   -- Set_Completion_Item_Documentation --
   ---------------------------------------

   procedure Set_Completion_Item_Documentation
     (Handler                 : in out LSP.Ada_Handlers.Message_Handler;
      Context                 : LSP.Ada_Contexts.Context;
      BD                      : Libadalang.Analysis.Basic_Decl;
      Item                    : in out LSP.Structures.CompletionItem;
      Compute_Doc_And_Details : Boolean)
   is
      use type VSS.Strings.Virtual_String;

   begin
      --  Compute the 'documentation' and 'detail' fields immediately if
      --  requested (i.e: when the client does not support lazy computation
      --  for these fields or if we are dealing with predefined types).
      if Compute_Doc_And_Details or else LSP.Utils.Is_Synthetic (BD) then
         declare
            Qual_Text    : VSS.Strings.Virtual_String;
            Decl_Text    : VSS.Strings.Virtual_String;
            Loc_Text     : VSS.Strings.Virtual_String;
            Doc_Text     : VSS.Strings.Virtual_String;
            Aspects_Text : VSS.Strings.Virtual_String;

         begin
            LSP.Ada_Documentation.Get_Tooltip_Text
              (BD                 => BD,
               Style              => Context.Get_Documentation_Style,
               Declaration_Text   => Decl_Text,
               Qualifier_Text     => Qual_Text,
               Location_Text      => Loc_Text,
               Documentation_Text => Doc_Text,
               Aspects_Text       => Aspects_Text);

            Item.detail := Decl_Text;

            if not Doc_Text.Is_Empty then
               Loc_Text.Append (2 * VSS.Characters.Latin.Line_Feed);
               Loc_Text.Append (Doc_Text);
            end if;

            Item.documentation :=
              (Is_Set => True,
               Value  => LSP.Structures.Virtual_String_Or_MarkupContent'
                 (Is_Virtual_String => True,
                  Virtual_String    => Loc_Text));
         end;

      else
         --  Set node's location to the 'data' field of the completion item, so
         --  that we can retrieve it in the completionItem/resolve handler.
         LSP.Structures.LSPAny_Vectors.To_Any
           (LSP.Ada_Handlers.Locations.To_LSP_Location (Handler, BD),
            Item.data);
      end if;
   end Set_Completion_Item_Documentation;

   ---------------------
   -- To_LSP_Location --
   ---------------------

   function To_LSP_Location
     (Self    : Document;
      Segment : Langkit_Support.Slocs.Source_Location_Range;
      Kinds   : LSP.Structures.AlsReferenceKind_Set := LSP.Constants.Empty)
      return LSP.Structures.Location
        is (uri     => Self.URI,
            a_range => Self.To_A_Range (Segment),
            alsKind => Kinds);

   ----------
   -- Unit --
   ----------

   function Unit
     (Self : Document'Class; Context : LSP.Ada_Contexts.Context)
      return Libadalang.Analysis.Analysis_Unit
   is
      (Context.LAL_Context.Get_From_File
        (Filename => Context.URI_To_File (Self.URI).Display_Full_Name,
         Charset  => Context.Charset,
         Reparse  => False));

end LSP.Ada_Documents;
